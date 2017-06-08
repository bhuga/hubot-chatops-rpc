slackHelper = {}
Client = require('@slack/client').WebClient

slackHelper.postSnippet = (channel, text, callback) ->
    client = new Client(process.env.HUBOT_SLACK_TOKEN)
    data = { content: text, channels: channel }
    client.files.upload "Hubot-uploaded file", data, (err, info) ->
      callback?(info)
