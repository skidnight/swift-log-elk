//
//  LogstashLogHandler.swift
//
//
//  Created by Philipp Zagar on 26.06.21.
//

import NIO
import NIOConcurrencyHelpers
import Logging
import AsyncHTTPClient
import Foundation

/// `LogstashLogHandler` is a simple implementation of `LogHandler` for directing
/// `Logger` output to Logstash via HTTP requests
public struct LogstashLogHandler: LogHandler {
    /// The label of the `LogHandler`
    let label: String
    /// The host where a Logstash instance is running
    let hostname: String
    /// The port of the host where a Logstash instance is running
    let port: Int
    /// The `EventLoopGroup` which is used to create the `HTTPClient`
    let eventLoopGroup: EventLoopGroup
    /// Used to log background activity of the `LogstashLogHandler` and `HTTPClient`
    /// This logger MUST be created BEFORE the `LoggingSystem` is bootstrapped, else it results in an infinte recusion!
    let backgroundActivityLogger: Logger
    /// Represents a certain amount of time which serves as a delay between the triggering of the uploading to Logstash
    let uploadInterval: TimeAmount
    /// Specifies how large the log storage `ByteBuffer` must be at least (`ByteBuffer` rounds up to a size to the power of two)
    let minimumLogStorageSize: Int

    /// The `HTTPClient` which is used to create the `HTTPClient.Request`
    let httpClient: HTTPClient
    /// The `HTTPClient.Request` which stays consistent (except the body) over all uploadings to Logstash
    @Boxed var httpRequest: HTTPClient.Request?

    /// The log storage byte buffer which serves as a cache of the log data entires
    @Boxed var byteBuffer: ByteBuffer
    /// Provides thread-safe access to the log storage byte buffer
    let byteBufferLock = ConditionLock(value: false)
    /// Created during scheduling of the upload function to Logstash, provides the ability to cancle the uploading task
    @Boxed private(set) var uploadTask: RepeatedTask?

    /// The default `Logger.Level` of the `LogstashLogHandler`
    /// Logging entries below this `Logger.Level` won't get logged at all
    public var logLevel: Logger.Level = .info
    /// Holds the `Logger.Metadata` of the `LogstashLogHandler`
    public var metadata = Logger.Metadata()
    /// Convenience subscript to get and set `Logger.Metadata`
    public subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get {
            self.metadata[metadataKey]
        }
        set {
            self.metadata[metadataKey] = newValue
        }
    }

    /// Creates a `LogstashLogHandler` that directs its output to Logstash
    // Make sure that the `backgroundActivityLogger` is instanciated BEFORE `LoggingSystem.bootstrap(...)` is called (currently not even possible otherwise)
    public init(label: String,
                hostname: String = "0.0.0.0",
                port: Int = 31311,
                eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1),
                backgroundActivityLogger: Logger = Logger(label: "backgroundActivity-logstashHandler"),
                uploadInterval: TimeAmount = TimeAmount.seconds(3),
                minimumLogStorageSize: Int = 1_048_576) throws {
        self.label = label
        self.hostname = hostname
        self.port = port
        self.httpClient = HTTPClient(
            eventLoopGroupProvider: .shared(eventLoopGroup),
            configuration: HTTPClient.Configuration(),
            backgroundActivityLogger: backgroundActivityLogger
        )

        self.eventLoopGroup = eventLoopGroup
        self.backgroundActivityLogger = backgroundActivityLogger
        self.uploadInterval = uploadInterval
        self.minimumLogStorageSize = minimumLogStorageSize

        // Need to be wrapped in a class since those properties can be mutated
        self._byteBuffer = Boxed(wrappedValue: ByteBufferAllocator().buffer(capacity: minimumLogStorageSize))
        self._uploadTask = Boxed(wrappedValue: scheduleUploadTask(initialDelay: uploadInterval))
        
        // Set a "super-secret" metadata value to validate that the backgroundActivityLogger
        // doesn't use the LogstashLogHandler as a logging backend
        // Currently, this behavior isn't even possible, but maybe in future versions of the swift-log package
        self[metadataKey: "super-secret-is-a-logstash-loghandler"] = .string("true")
        
        // Check if backgroundActivityLogger doesn't use the LogstashLogHandler as a logging backend
        if let usesLogstashHandlerValue = backgroundActivityLogger[metadataKey: "super-secret-is-a-logstash-loghandler"],
           case .string(let usesLogstashHandler) = usesLogstashHandlerValue,
           usesLogstashHandler == "true" {
            try self.httpClient.syncShutdown()
            self.uploadTask?.cancel(promise: nil)
            
            throw Error.backgroundActivityLoggerBackendError
        }
    }

    /// The main log function of the `LogstashLogHandler`
    /// Merges the `Logger.Metadata`, encodes the log entry to a propertly formatted HTTP body
    /// which is then cached in the log store `ByteBuffer`
    // This function is thread-safe via a `ConditionalLock` on the log store `ByteBuffer`
    public func log(level: Logger.Level,            // swiftlint:disable:this function_parameter_count function_body_length
                    message: Logger.Message,
                    metadata: Logger.Metadata?,
                    source: String,
                    file: String,
                    function: String,
                    line: UInt) {
        let mergedMetadata = mergeMetadata(passedMetadata: metadata, file: file, function: function, line: line)

        guard let logData = encodeLogData(level: level, message: message, metadata: mergedMetadata) else {
            self.backgroundActivityLogger.log(
                level: .warning,
                "Error during encoding log data",
                metadata: [
                    "label": .string(self.label),
                    "logEntry": .dictionary(
                        [
                            "message": .string(message.description),
                            "metadata": .dictionary(mergedMetadata),
                            "logLevel": .string(level.rawValue)
                        ]
                    )
                ]
            )

            return
        }
        
        // The conditional lock ensures that the uploading function is not "manually" scheduled multiple times
        // The state of the lock, in this case "false", indicates, that the byteBuffer isn't full at the moment
        guard self.byteBufferLock.lock(whenValue: false, timeoutSeconds: TimeAmount.seconds(1).rawSeconds) else {
            // If lock couldn't be aquired, don't log the data and just return
            self.backgroundActivityLogger.log(
                level: .warning,
                "Lock on the log data byte buffer couldn't be aquired",
                metadata: [
                    "label": .string(self.label),
                    "logStorage": .dictionary(
                        [
                            "readableBytes": .string("\(self.byteBuffer.readableBytes)"),
                            "writableBytes": .string("\(self.byteBuffer.writableBytes)"),
                            "readerIndex": .string("\(self.byteBuffer.readerIndex)"),
                            "writerIndex": .string("\(self.byteBuffer.writerIndex)"),
                            "capacity": .string("\(self.byteBuffer.capacity)")
                        ]
                    ),
                    "conditionalLockState": .string("\(self.byteBufferLock.value)")
                ]
            )
            
            return
        }

        // Check if the maximum storage size of the byte buffer would be exeeded.
        // If that's the case, trigger the uploading of the logs manually
        if (self.byteBuffer.readableBytes + MemoryLayout<Int>.size + logData.count) > self.byteBuffer.capacity {
            // A single log entry is larger than the current byte buffer size
            if self.byteBuffer.readableBytes == 0 {
                self.backgroundActivityLogger.log(
                    level: .warning,
                    "A single log entry is larger than the configured log storage size",
                    metadata: [
                        "label": .string(self.label),
                        "logStorageSize": .string("\(self.byteBuffer.capacity)"),
                        "logEntry": .dictionary(
                            [
                                "message": .string(message.description),
                                "metadata": .dictionary(mergedMetadata),
                                "logLevel": .string(level.rawValue),
                                "size": .string("\(logData.count)")
                            ]
                        )
                    ]
                )
                
                self.byteBufferLock.unlock()
                return
            }
            
            // Cancle the "old" upload task
            self.uploadTask?.cancel(promise: nil)

            // Trigger the upload task immediatly
            self.uploadTask = scheduleUploadTask(initialDelay: TimeAmount.zero)

            // The state of the lock, in this case "true", indicates, that the byteBuffer
            // is full at the moment and must be emptied before writing to it again
            self.byteBufferLock.unlock(withValue: true)
        } else {
            self.byteBufferLock.unlock()
        }

        guard self.byteBufferLock.lock(whenValue: false, timeoutSeconds: TimeAmount.seconds(1).rawSeconds) else {
            // If lock couldn't be aquired, don't log the data and just return
            self.backgroundActivityLogger.log(
                level: .warning,
                "Lock on the log data byte buffer couldn't be aquired",
                metadata: [
                    "label": .string(self.label),
                    "logStorage": .dictionary(
                        [
                            "readableBytes": .string("\(self.byteBuffer.readableBytes)"),
                            "writableBytes": .string("\(self.byteBuffer.writableBytes)"),
                            "readerIndex": .string("\(self.byteBuffer.readerIndex)"),
                            "writerIndex": .string("\(self.byteBuffer.writerIndex)"),
                            "capacity": .string("\(self.byteBuffer.capacity)")
                        ]
                    ),
                    "conditionalLockState": .string("\(self.byteBufferLock.value)")
                ]
            )
            
            return
        }

        // Write size of the log data
        self.byteBuffer.writeInteger(logData.count)
        // Write actual log data to log store
        self.byteBuffer.writeData(logData)

        self.byteBufferLock.unlock()
    }
}
