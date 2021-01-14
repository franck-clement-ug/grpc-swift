/*
 * Copyright 2021, gRPC Authors All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
@testable import GRPC
import NIO
import NIOHPACK
import XCTest

// MARK: - Utils

final class ResponseRecorder: GRPCServerResponseWriter {
  var metadata: HPACKHeaders?
  var messages: [ByteBuffer] = []
  var status: GRPCStatus?
  var trailers: HPACKHeaders?

  func sendMetadata(_ metadata: HPACKHeaders, promise: EventLoopPromise<Void>?) {
    XCTAssertNil(self.metadata)
    self.metadata = metadata
    promise?.succeed(())
  }

  func sendMessage(
    _ bytes: ByteBuffer,
    metadata: MessageMetadata,
    promise: EventLoopPromise<Void>?
  ) {
    self.messages.append(bytes)
    promise?.succeed(())
  }

  func sendEnd(status: GRPCStatus, trailers: HPACKHeaders, promise: EventLoopPromise<Void>?) {
    XCTAssertNil(self.status)
    XCTAssertNil(self.trailers)
    self.status = status
    self.trailers = trailers
    promise?.succeed(())
  }
}

protocol ServerHandlerTestCase: GRPCTestCase {
  var eventLoop: EmbeddedEventLoop { get }
  var allocator: ByteBufferAllocator { get }
  var recorder: ResponseRecorder { get }
}

extension ServerHandlerTestCase {
  func makeCallHandlerContext() -> CallHandlerContext {
    return CallHandlerContext(
      errorDelegate: nil,
      logger: self.logger,
      encoding: .disabled,
      eventLoop: self.eventLoop,
      path: "/ignored",
      remoteAddress: nil,
      responseWriter: self.recorder,
      allocator: self.allocator
    )
  }
}

// MARK: - Unary

class UnaryServerHandlerTests: GRPCTestCase, ServerHandlerTestCase {
  let eventLoop = EmbeddedEventLoop()
  let allocator = ByteBufferAllocator()
  let recorder = ResponseRecorder()

  private func makeHandler(
    function: @escaping (String, StatusOnlyCallContext) -> EventLoopFuture<String>
  ) -> UnaryServerHandler<StringSerializer, StringDeserializer> {
    return UnaryServerHandler(
      context: self.makeCallHandlerContext(),
      requestDeserializer: StringDeserializer(),
      responseSerializer: StringSerializer(),
      interceptors: [],
      userFunction: function
    )
  }

  private func echo(_ request: String, context: StatusOnlyCallContext) -> EventLoopFuture<String> {
    return context.eventLoop.makeSucceededFuture(request)
  }

  private func neverComplete(
    _ request: String,
    context: StatusOnlyCallContext
  ) -> EventLoopFuture<String> {
    let scheduled = context.eventLoop.scheduleTask(deadline: .distantFuture) {
      return request
    }
    return scheduled.futureResult
  }

  private func neverCalled(
    _ request: String,
    context: StatusOnlyCallContext
  ) -> EventLoopFuture<String> {
    XCTFail("Unexpected function invocation")
    return context.eventLoop.makeFailedFuture(GRPCError.InvalidState(""))
  }

  func testHappyPath() {
    let handler = self.makeHandler(function: self.echo(_:context:))

    handler.receiveMetadata([:])
    assertThat(self.recorder.metadata, .is([:]))

    let buffer = ByteBuffer(string: "hello")
    handler.receiveMessage(buffer)
    handler.receiveEnd()
    handler.finish()

    assertThat(self.recorder.messages.first, .is(buffer))
    assertThat(self.recorder.status, .notNil(.hasCode(.ok)))
    assertThat(self.recorder.trailers, .is([:]))
  }

  func testThrowingDeserializer() {
    let handler = UnaryServerHandler(
      context: self.makeCallHandlerContext(),
      requestDeserializer: ThrowingStringDeserializer(),
      responseSerializer: StringSerializer(),
      interceptors: [],
      userFunction: self.neverCalled(_:context:)
    )

    handler.receiveMetadata([:])
    assertThat(self.recorder.metadata, .is([:]))

    let buffer = ByteBuffer(string: "hello")
    handler.receiveMessage(buffer)

    assertThat(self.recorder.messages, .isEmpty())
    assertThat(self.recorder.status, .notNil(.hasCode(.internalError)))
  }

  func testThrowingSerializer() {
    let handler = UnaryServerHandler(
      context: self.makeCallHandlerContext(),
      requestDeserializer: StringDeserializer(),
      responseSerializer: ThrowingStringSerializer(),
      interceptors: [],
      userFunction: self.echo(_:context:)
    )

    handler.receiveMetadata([:])
    assertThat(self.recorder.metadata, .is([:]))

    let buffer = ByteBuffer(string: "hello")
    handler.receiveMessage(buffer)
    handler.receiveEnd()

    assertThat(self.recorder.messages, .isEmpty())
    assertThat(self.recorder.status, .notNil(.hasCode(.internalError)))
  }

  func testUserFunctionReturnsFailedFuture() {
    let handler = self.makeHandler { _, context in
      return context.eventLoop.makeFailedFuture(GRPCStatus(code: .unavailable, message: ":("))
    }

    handler.receiveMetadata([:])
    assertThat(self.recorder.metadata, .is([:]))

    let buffer = ByteBuffer(string: "hello")
    handler.receiveMessage(buffer)

    assertThat(self.recorder.messages, .isEmpty())
    assertThat(self.recorder.status, .notNil(.hasCode(.unavailable)))
    assertThat(self.recorder.status?.message, .is(":("))
  }

  func testReceiveMessageBeforeHeaders() {
    let handler = self.makeHandler(function: self.neverCalled(_:context:))

    handler.receiveMessage(ByteBuffer(string: "foo"))
    assertThat(self.recorder.metadata, .is(.nil()))
    assertThat(self.recorder.messages, .isEmpty())
    assertThat(self.recorder.status, .notNil(.hasCode(.internalError)))
  }

  func testReceiveMultipleHeaders() {
    let handler = self.makeHandler(function: self.neverCalled(_:context:))

    handler.receiveMetadata([:])
    assertThat(self.recorder.metadata, .is([:]))

    handler.receiveMetadata([:])
    assertThat(self.recorder.messages, .isEmpty())
    assertThat(self.recorder.status, .notNil(.hasCode(.internalError)))
  }

  func testReceiveMultipleMessages() {
    let handler = self.makeHandler(function: self.neverComplete(_:context:))

    handler.receiveMetadata([:])
    assertThat(self.recorder.metadata, .is([:]))

    let buffer = ByteBuffer(string: "hello")
    handler.receiveMessage(buffer)
    handler.receiveEnd()
    // Send another message before the function completes.
    handler.receiveMessage(buffer)

    assertThat(self.recorder.messages, .isEmpty())
    assertThat(self.recorder.status, .notNil(.hasCode(.internalError)))
  }

  func testFinishBeforeStarting() {
    let handler = self.makeHandler(function: self.neverCalled(_:context:))

    handler.finish()
    assertThat(self.recorder.metadata, .is(.nil()))
    assertThat(self.recorder.messages, .isEmpty())
    assertThat(self.recorder.status, .is(.nil()))
    assertThat(self.recorder.trailers, .is(.nil()))
  }

  func testFinishAfterHeaders() {
    let handler = self.makeHandler(function: self.neverCalled(_:context:))
    handler.receiveMetadata([:])
    assertThat(self.recorder.metadata, .is([:]))

    handler.finish()

    assertThat(self.recorder.messages, .isEmpty())
    assertThat(self.recorder.status, .notNil(.hasCode(.unavailable)))
    assertThat(self.recorder.trailers, .is([:]))
  }

  func testFinishAfterMessage() {
    let handler = self.makeHandler(function: self.neverComplete(_:context:))

    handler.receiveMetadata([:])
    handler.receiveMessage(ByteBuffer(string: "hello"))
    handler.finish()

    assertThat(self.recorder.messages, .isEmpty())
    assertThat(self.recorder.status, .notNil(.hasCode(.unavailable)))
    assertThat(self.recorder.trailers, .is([:]))
  }
}

// MARK: - Client Streaming

class ClientStreamingServerHandlerTests: GRPCTestCase, ServerHandlerTestCase {
  let eventLoop = EmbeddedEventLoop()
  let allocator = ByteBufferAllocator()
  let recorder = ResponseRecorder()

  private func makeHandler(
    observerFactory: @escaping (UnaryResponseCallContext<String>)
      -> EventLoopFuture<(StreamEvent<String>) -> Void>
  ) -> ClientStreamingServerHandler<StringSerializer, StringDeserializer> {
    return ClientStreamingServerHandler(
      context: self.makeCallHandlerContext(),
      requestDeserializer: StringDeserializer(),
      responseSerializer: StringSerializer(),
      interceptors: [],
      observerFactory: observerFactory
    )
  }

  private func joinWithSpaces(
    context: UnaryResponseCallContext<String>
  ) -> EventLoopFuture<(StreamEvent<String>) -> Void> {
    var messages: [String] = []
    func onEvent(_ event: StreamEvent<String>) {
      switch event {
      case let .message(message):
        messages.append(message)
      case .end:
        context.responsePromise.succeed(messages.joined(separator: " "))
      }
    }
    return context.eventLoop.makeSucceededFuture(onEvent(_:))
  }

  private func neverReceivesMessage(
    context: UnaryResponseCallContext<String>
  ) -> EventLoopFuture<(StreamEvent<String>) -> Void> {
    func onEvent(_ event: StreamEvent<String>) {
      switch event {
      case let .message(message):
        XCTFail("Unexpected message: '\(message)'")
      case .end:
        context.responsePromise.succeed("")
      }
    }
    return context.eventLoop.makeSucceededFuture(onEvent(_:))
  }

  private func neverCalled(
    context: UnaryResponseCallContext<String>
  ) -> EventLoopFuture<(StreamEvent<String>) -> Void> {
    XCTFail("This observer factory should never be called")
    return context.eventLoop.makeFailedFuture(GRPCStatus(code: .aborted, message: nil))
  }

  func testHappyPath() {
    let handler = self.makeHandler(observerFactory: self.joinWithSpaces(context:))

    handler.receiveMetadata([:])
    assertThat(self.recorder.metadata, .is([:]))

    handler.receiveMessage(ByteBuffer(string: "1"))
    handler.receiveMessage(ByteBuffer(string: "2"))
    handler.receiveMessage(ByteBuffer(string: "3"))
    handler.receiveEnd()
    handler.finish()

    assertThat(self.recorder.messages.first, .is(ByteBuffer(string: "1 2 3")))
    assertThat(self.recorder.status, .notNil(.hasCode(.ok)))
    assertThat(self.recorder.trailers, .is([:]))
  }

  func testThrowingDeserializer() {
    let handler = ClientStreamingServerHandler(
      context: self.makeCallHandlerContext(),
      requestDeserializer: ThrowingStringDeserializer(),
      responseSerializer: StringSerializer(),
      interceptors: [],
      observerFactory: self.neverReceivesMessage(context:)
    )

    handler.receiveMetadata([:])
    assertThat(self.recorder.metadata, .is([:]))

    let buffer = ByteBuffer(string: "hello")
    handler.receiveMessage(buffer)

    assertThat(self.recorder.messages, .isEmpty())
    assertThat(self.recorder.status, .notNil(.hasCode(.internalError)))
  }

  func testThrowingSerializer() {
    let handler = ClientStreamingServerHandler(
      context: self.makeCallHandlerContext(),
      requestDeserializer: StringDeserializer(),
      responseSerializer: ThrowingStringSerializer(),
      interceptors: [],
      observerFactory: self.joinWithSpaces(context:)
    )

    handler.receiveMetadata([:])
    assertThat(self.recorder.metadata, .is([:]))

    let buffer = ByteBuffer(string: "hello")
    handler.receiveMessage(buffer)
    handler.receiveEnd()

    assertThat(self.recorder.messages, .isEmpty())
    assertThat(self.recorder.status, .notNil(.hasCode(.internalError)))
  }

  func testObserverFactoryReturnsFailedFuture() {
    let handler = self.makeHandler { context in
      context.eventLoop.makeFailedFuture(GRPCStatus(code: .unavailable, message: ":("))
    }

    handler.receiveMetadata([:])
    assertThat(self.recorder.messages, .isEmpty())
    assertThat(self.recorder.status, .notNil(.hasCode(.unavailable)))
    assertThat(self.recorder.status?.message, .is(":("))
  }

  func testDelayedObserverFactory() {
    let promise = self.eventLoop.makePromise(of: Void.self)
    let handler = self.makeHandler { context in
      return promise.futureResult.flatMap {
        self.joinWithSpaces(context: context)
      }
    }

    handler.receiveMetadata([:])
    // Queue up some messages.
    handler.receiveMessage(ByteBuffer(string: "1"))
    handler.receiveMessage(ByteBuffer(string: "2"))
    handler.receiveMessage(ByteBuffer(string: "3"))
    // Succeed the observer block.
    promise.succeed(())
    // A few more messages.
    handler.receiveMessage(ByteBuffer(string: "4"))
    handler.receiveMessage(ByteBuffer(string: "5"))
    handler.receiveEnd()

    assertThat(self.recorder.messages.first, .is(ByteBuffer(string: "1 2 3 4 5")))
    assertThat(self.recorder.status, .notNil(.hasCode(.ok)))
  }

  func testDelayedObserverFactoryAllMessagesBeforeSucceeding() {
    let promise = self.eventLoop.makePromise(of: Void.self)
    let handler = self.makeHandler { context in
      return promise.futureResult.flatMap {
        self.joinWithSpaces(context: context)
      }
    }

    handler.receiveMetadata([:])
    // Queue up some messages.
    handler.receiveMessage(ByteBuffer(string: "1"))
    handler.receiveMessage(ByteBuffer(string: "2"))
    handler.receiveMessage(ByteBuffer(string: "3"))
    handler.receiveEnd()
    // Succeed the observer block.
    promise.succeed(())

    assertThat(self.recorder.messages.first, .is(ByteBuffer(string: "1 2 3")))
    assertThat(self.recorder.status, .notNil(.hasCode(.ok)))
  }

  func testReceiveMessageBeforeHeaders() {
    let handler = self.makeHandler(observerFactory: self.neverCalled(context:))

    handler.receiveMessage(ByteBuffer(string: "foo"))
    assertThat(self.recorder.metadata, .is(.nil()))
    assertThat(self.recorder.messages, .isEmpty())
    assertThat(self.recorder.status, .notNil(.hasCode(.internalError)))
  }

  func testReceiveMultipleHeaders() {
    let handler = self.makeHandler(observerFactory: self.neverReceivesMessage(context:))

    handler.receiveMetadata([:])
    assertThat(self.recorder.metadata, .is([:]))

    handler.receiveMetadata([:])
    assertThat(self.recorder.messages, .isEmpty())
    assertThat(self.recorder.status, .notNil(.hasCode(.internalError)))
  }

  func testFinishBeforeStarting() {
    let handler = self.makeHandler(observerFactory: self.neverCalled(context:))

    handler.finish()
    assertThat(self.recorder.metadata, .is(.nil()))
    assertThat(self.recorder.messages, .isEmpty())
    assertThat(self.recorder.status, .is(.nil()))
    assertThat(self.recorder.trailers, .is(.nil()))
  }

  func testFinishAfterHeaders() {
    let handler = self.makeHandler(observerFactory: self.joinWithSpaces(context:))
    handler.receiveMetadata([:])
    assertThat(self.recorder.metadata, .is([:]))

    handler.finish()

    assertThat(self.recorder.messages, .isEmpty())
    assertThat(self.recorder.status, .notNil(.hasCode(.unavailable)))
    assertThat(self.recorder.trailers, .is([:]))
  }

  func testFinishAfterMessage() {
    let handler = self.makeHandler(observerFactory: self.joinWithSpaces(context:))

    handler.receiveMetadata([:])
    handler.receiveMessage(ByteBuffer(string: "hello"))
    handler.finish()

    assertThat(self.recorder.messages, .isEmpty())
    assertThat(self.recorder.status, .notNil(.hasCode(.unavailable)))
    assertThat(self.recorder.trailers, .is([:]))
  }
}