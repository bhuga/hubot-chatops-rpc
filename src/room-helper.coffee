Channel = require("@slack/client/lib/models/channel")
DM = require("@slack/client/lib/models/dm")
Group = require("@slack/client/lib/models/group")

get_room = (robot, room_id) ->
  if robot.adapterName is "slack"
    return robot.adapter.client.rtm.dataStore.getChannelGroupOrDMById(room_id)
  else
    return robot.rooms[room_id]

get_user = (robot, user_id) ->
  if robot.adapterName is "slack"
    return robot.adapter.client.rtm.dataStore.getUserById(user_id)
  else
    return user_id

get_user_name = (robot, user_id) ->
  if robot.adapterName is "slack"
    return get_user(robot, user_id).name
  else
    return user_id

get_room_name = (robot, room_id) ->
  if robot.adapterName is "slack"
    room = get_room(robot, room_id)
    return room_id unless room

    return room.name if room instanceof Channel or room instanceof Group

    # In earlier versions, the room name for a DM was the creator's name.
    # Now, the DM object returned has a `name` value that's not useful to us;
    # if that happens, look up the user and get their name to
    # reproduce the old behaviour.
    if is_dm(robot, room_id)
      return get_user_name(robot, room.user)
  else
    return room_id

is_dm = (robot, room_id) ->
  if robot.adapterName is "slack"
    return robot.adapter.client.rtm.dataStore.getChannelGroupOrDMById(room_id) instanceof DM
  else
    return false

is_mpdm = (robot, room_id) ->
  if robot.adapterName is "slack"
    return robot.adapter.client.rtm.dataStore.getChannelGroupOrDMById(room_id) instanceof Group
  else
    return false

is_private = (robot, room_id) ->
  return is_dm(robot, room_id) || is_mpdm(robot, room_id)

module.exports = {
  get_room: get_room,
  get_user: get_user,
  get_user_name: get_user_name,
  get_room_name: get_room_name,
  is_dm: is_dm,
  is_mpdm: is_mpdm,
  is_private: is_private,
}
