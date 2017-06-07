http   = require 'http'
fs     = require 'fs'
crypto = require 'crypto'

Helper = require('hubot-test-helper')
assert = require('chai').assert
chai = require 'chai'

helper = new Helper('../src/chatops-rpc.coffee')

describe 'chatops-rpc', ->
  beforeEach (doneBeforeEach) ->
    process.env.RPC_PRIVATE_KEY = fs.readFileSync("test/hubot-test.pem")
    process.env.RPC_PUBLIC_KEY = fs.readFileSync("test/hubot-test.pub")

    @chatopListing =
      namespace: "deploy"
      help: "generic help about deployments\ntwo lines of it"
      methods:
        wcid:
          help: "where you can deploy?"
          regex: "(?:where can i deploy|wcid)(?: (?<app>\\S+))?",
          params: ["app", "generic_argument", "argument2"]
          path: "wcid"

    @server = http.createServer()
    @sockets = {}
    @nextSocketId = 0
    # Listen on localhost on a unique port.
    @server.listen =>
      @serverURL = "http://localhost:#{@server.address().port}"
      @chatopsUrl = "http://localhost:#{@server.address().port}/_chatops"
      console.log("done listening")
      doneBeforeEach()

    @server.on 'connection', (socket) =>
      socketId = @nextSocketId++
      @sockets[socketId] = socket
      socket.on 'close', () =>
        delete @sockets[socketId]

    @room = helper.createRoom(httpd: false)
    @room.robot.adapterName = "mock-adapter"
    @room.robot.name = "hubot"
  #
  afterEach ->
     @room.destroy()

  defaultServerResponder = (chatopListing) ->
    return (request, response) ->
      if request.url is "/_chatops"
        response.write JSON.stringify(chatopListing)
        response.end()
      else if request.url is "/_chatops/wcid"
        jsonrpcResponse =
          jsonrpc: "2.0",
          id: null,
          result: "foo response!"
        body = []
        request.on 'data', (chunk) ->
          body.push chunk
        .on 'end', ->
          body = Buffer.concat(body).toString()
          data = JSON.parse(body)
          if data.params.generic_argument? || data.params.boolean_arg?
            app = if data.params.app? then ", app was #{data.params.app}" else ", app is empty"
            arg2 = if data.params.argument2? then ", arg2 is #{data.params.argument2}" else ""
            bool = if data.params.boolean_arg? then ", boolean arg was #{data.params.boolean_arg}" else ""
            jsonrpcResponse.result = "a generic argument of #{data.params.generic_argument} was sent#{arg2}#{bool}#{app}"
          else if data.params.app?
            jsonrpcResponse.result = "foo response about #{data.params.app}!"
          response.write JSON.stringify(jsonrpcResponse)
          response.end()
      else
        error = new Error "Should not have received request: #{request.method} #{request.url}"
        response.end()

  it 'adds a server', ->
    error = null
    @server.on 'request', defaultServerResponder(@chatopListing)
    @room.user.say('alice', "hubot rpc add #{@chatopsUrl}").then =>
      console.log("done huboting")
      chai.expect(@room.messages).to.eql [
        ['alice', "hubot rpc add #{@chatopsUrl}"]
        ['hubot', "@alice Okay, I'll poll #{@chatopsUrl} for chatops."]
        ['hubot', "#{@chatopsUrl}: Found 1 method."]
      ]
      @room.user.say('alice', "hubot wcid").then =>
        assert.include @room.messages[0][1], "foo response!"
