Path  = require 'path'
hubot = require 'hubot'

# Creates a Robot instance for testing. robot.adapter will be a
# hubot-mock-adapter instance, which can be used for sending messages to the
# robot and listening for replies.
exports.robot = ->
  # We specify the shell adapter here but point the robot at the test
  # directory. This will make it find our shell.coffee symlink, which points
  # to our test-adapter.coffee module.
  robot = hubot.loadBot null, 'mock-adapter', false, 'TestHubot'

  robot.alias = '/'
  robot.rooms = {}

  # Rethrow any errors that are generated while handling messages. Normally
  # Hubot catches these and logs them.
  error = null
  robot.error (e) ->
    error = e
  originalReceive = robot.adapter.receive
  robot.adapter.receive = ->
    error = null
    result = originalReceive.apply this, arguments
    throw error if error?
    result

  robot

# Creates a new User instance for testing.
exports.testUser = (robot) ->
  ids = Object.keys robot.brain.users()
  highestID = if ids.length
    Math.max ids...
  else
    0
  id = highestID + 1
  user = robot.brain.userForId id, name: "TestUser#{id}", room: 'TestRoom'
  user.githubLogin = "TestUser#{id}GitHubLogin"
  user

# The path to the top-level scripts/ directory. Useful in conjunction with
# robot.loadFile().
exports.SCRIPTS_PATH = Path.join __dirname, '..', 'src'

# Sends one or more TextMessages to the robot. Waits for a response to each
# message before sending the next one. The callback is called when the response
# to the final message is received.
#
# robot    - a Robot instance (usually from helper.robot())
# user     - a User instance (usually from helper.testUser())
# messages - one or more String arguments
# callback - the optional callback to call once the last response has been sent
#
#   helper.converse @robot, @user, '/image me giraffe', '/ping', (envelope, response) ->
#     assert.equal response, 'PONG'
#
#   helper.converse @robot, @user, '/corgi bomb', (envelope, responses...) ->
#     assert.equal responses.length, 5
#     for response in responses
#       assert.include response, 'corgi'
exports.converse = (robot, user, messages..., callback) ->
  EVENTS = ['send', 'reply']

  unless messages.length
    messages = [callback]
    callback = null

  receivedResponse = (envelope, strings) ->
    for event in EVENTS
      robot.adapter.removeListener event, receivedResponse

    if messages.length
      sendNextMessage()
    else
      callback? envelope, strings...

  sendNextMessage = ->
    for event in EVENTS
      robot.adapter.once event, receivedResponse
    message = messages.shift()
    robot.adapter.receive new hubot.TextMessage user, message

  sendNextMessage()
