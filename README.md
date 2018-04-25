# hubot-chatops-rpc

Easily add RPC endpoints to your hubot.

Chatops RPC is an extraction of years of experience with Chatops at GitHub. It's
a simple protocol based on JSON-RPC over HTTPS. Chatops RPC pushes all of the
code save parsing to a server for processing. This means that chat commands can
be written and tested entirely server-side, without any glue code in hubot/node.

This module is the client in the Chatops RPC protocol. Hubot stores a list of
servers and the endpoints they offer in his brain.

For more information, see the [protocol description](#protocol-description)

## Usage

To add a chatops RPC server, use:

`.rpc add https://example.com/_chatops --prefix example`

This will add `https://example.com/_chatops` to the list of endpoints. Hubot
will poll this endpoint every 10 seconds for commands. All commands from this
endpoint will require a prefix of `example`.

To remove a server:

`.rpc remove https://example.com/_chatops`

To see a server's response:

`.rpc debug https://example.com/_chatops`

Commands from this endpoint will be prefixed with `example`. Assume the endpoint
exposes an endpoint with the regex `/ping/`. The command will be accessible
with:

`.example ping`

Hubot will parse long-form arguments, such as `--argument1 foo bar`, and send
them to the server as additional arguments. These can be added to any command,
so `.example ping --reason just because we feel like it` will call the `ping`
method with an extra argument of `{ reason: "just because we feel like it"}`.

---

## Protocol Description

CRPC is a client-server protocol; Hubot is a client. Servers expose an endpoint
listing available methods. Each endpoint provides a regex to fire on and a
relative URL path to execute it.

Chatops RPC pushes a lot of complexity to clients. This is a design decision,
intended to keep the burden of creating new chat commands in existing systems
as low as possible.

## Listing Commands

A CRPC service listing is an endpoint that exposes JSON including the following
fields:

 * `namespace`: A globally unique namespace for these commands. Clients can use this to uniquely identify this endpoint. A namespace should be a slug of the form `/[a-Z0-9\-_]+/`.
 * `help`: **Optional:** Overall help for this namespace, if a client chooses to provide help
 * `error_response`: **Optional:** A message to present when this endpoint returns an error. This can direct users to next steps when the server fails.
 * `methods`: A mapping of named operations to their metadata.
 * `version`: The version of ChatOps RPC protocol to use, currently version 3

Each key in the `methods` hash will be a string name. Each name should be a
slug of the form `/[a-Z0-9]\-_]+/`. Clients can use these method names to uniquely
identify methods within a namespace. Each name shall point to an object with the
following fields:

 * `regex`: A string regular expression source used to execute the command. This regular expression should use named capture groups of the form `(?<parameter_name>.+)`.
 * `path`: A path, relative to the listing URL, to execute the command.
 * `params`: A list of available named parameters for this command.
 * `help`: **Optional:** User help for a given command.

Each server is assumed to be given a prefix, which the client will handle
prepending to a command's regex source. Clients can use the `namespace` as a
default prefix if they wish, but servers may not demand a particular prefix.
Chatops RPC clients should require whitespace after the prefix, so a command with a
regex like `/ping/` with a prefix of `test` would match on `test ping`.

## Executing Commands

CRPC clients use the listings to create a listing of available commands. When a
chat message matches a command's regex matcher, the CRPC client creates a method
invocation. A method invocation is a JSON object with the following fields:

 * `user`: A slug username corresponding to to the command giver's GitHub login.
 * `room_id`: A slug room name where the command originated.
 * `method`: The method name, without namespace, of the matching regex.
 * `params`: A mapping of parameter names to matches extracted from named capture groups in the command's regex. Parameters that are empty or null should not be passed.

The JSON object is posted to the `path` associated with the command from the
listing of commands. CRPC servers should assume that parameters in the `params`
hash are under user control, but trust that the `user` and `room_id` to be
correct.

CRPC servers must produce a response JSON object with the following fields:

 * `result`: A string to be displayed in the originating chat room.

CRPC may optionally include the following fields in a response JSON object for
use in situations where richer results can be displayed. Clients will optionally
utilize some or all of the extra information to provide an enhanced response,
but it is important that `result` be sufficient on its own.

 * `title`: The title text for the response
 * `title_link`: Optional URL to link the title text to
 * `color`: Hex color for the message, to indicate status/group e.g. "ddeeaa'
 * `buttons`: An array of button objects
    * `label`: The text to display on the button
    * `image_url`: An image URL to display as the button, will generally take precedence
    * `command`: The command to use when the button is clicked
 * `image_url`: An image URL to be included with the response

CRPC may also produce error JSON according to the JSON-RPC spec, consisting of
an object containing an `error` object with a `message` string. This is
sometimes helpful for clients that make a distinction between failed and
successful commands, such as a terminal. CRPC point of view. CRPC clients should
still parse these error messages.

## Examples

Here is an end-to-end transaction, sans authentication (see below):

CRPC client issues:
```
GET /_chatops HTTP/1.1
Accept: application/json

{
 "namespace": "deploy",
 "help": null,
 "version": 3,
 "error_response": "The server had an unexpected error. More information is perhaps available in the [error tracker](https://example.com)"
 "methods": {
   "options": {
     "help": "hubot deploy options <app> - List available environments for <app>",
     "regex": "options(?: (?<app>\\S+))?",
     "params": [
       "app"
     ],
     "path": "wcid"
   }
 }
}
```

The client will use the suggested `namespace` as a prefix, `deploy`. Thus, when
the client receives a command matching `.deploy options hubot`, the CRPC client
issues:

```
POST /_chatops/wcid HTTP/1.1
Accept: application/json
Content-type: application/json
Content-length: 77

{"user":"bhuga","method":"wcid","params":{"app": "hubot"},"room_id":"developer-experience"}
```

The CRPC server should respond with output like the following:

```
{"result":"Hubot is unlocked in production, you're free to deploy.\nHubot is unlocked in staging, you're free to deploy.\n"}
```

The CRPC client should output "Hubot is unlocked in production, you're free to
deploy.\nHubot is unlocked in staging, you're free to deploy.\n" to the chat
room. The client can optionally display the output intelligently if it contains
newlines, links in formats like markdown, etc. It's strongly recommended that
a client support markdown links if possible.

## Authentication

#### Authenticating clients

Clients authenticate themselves to servers by signing requests with RS256
using a private key. Servers have a public key associated with clients and
verify the signature with it.

By convention, a CRPC server should allow authentication with two secrets
simultaneously to allow seamless token rolling.

Clients send three additional HTTP headers for authentication: `Chatops-Nonce`,
`Chatops-timestamp`, and `Chatops-Signature`.

 * `Chatops-Nonce`: A random, base64-encoded string unique to every chatops
 request. Servers can cache seen nonces and refuse to execute them a second time.
 * `Chatops-Timestamp`: An ISO 8601 time signature in UTC, such as
 `2017-05-11T19:15:23Z`.
 * `Chatops-Signature`: The signature for this request.

The value to be signed is formed by concatenating the value of the full http path,
followed by a newline character, followed by the contents of the nonce
header, followed by a newline character, followed by the value of the timestamp header,
followed by a newline character, followed by the entire HTTP post body, if any. For example,
for a `GET` request with these headers:

```
Chatops-Nonce: abc123
Chatops-Timestamp: 2017-05-11T19:15:23Z
```

Sent to the following URL:

`https://example.com/_chatops`

The string to be signed is:
`https://example.com/_chatops\nabc123\n2017-05-11T19:15:23Z\n`

For a request with the same headers and a POST body of `{"method": "foo"}`, the
string to be signed is:

`https://example.com/_chatops\nabc123.2017-05-11T19:15:23Z\n{"method": "foo"}`

The signature header starts with the word `Signature`, followed by whitespace,
followed by comma-separated key-value pairs separated by an `=`. Keys must
be all lowercase.

 * `keyid`: An implementation-specific key identifier that servers can use to
 determine which private key signed this request.
 * `signature`: The base64-encoded RSA-SHA256 signature of the signing string.

An example signature header would be:

`Chatops-Signature: Signature keyid=rsakey1,signature=<base64-encoded-signature>`

#### Authentication

CRPC must trust that a user is authenticated by the `user` parameter sent with
every command. Individual servers may request a second authentication factor
after receiving a command; this is beyond the scope of CRPC.

#### Authorization

CRPC servers are responsible for ensuring that the given `user` has the proper
authorization to perform an operation.

### Execution

Chatops RPC clients are expected to add a few niceties not covered by the wire
protocol. This complexity is exported to clients to keep the burden of
implementing new automation low.

 * Regex anchoring. Clients should anchor regexes received from servers. If a
 command is exported as `where can i deploy`, it should not be triggered on
 `tell me where i can deploy` or `where can i deploy, i'm bored`.
 * Prefixing. Different execution contexts may prefix commands, such as `.`,
 `hubot`, or another sigil.
 * Help display systems. These are heavily context dependent. Servers provide
 text snippets about commands, but accessing and displaying them is up to the
 client.

These niceties are optional and context-dependent. Different clients may or may
not implement them. But if any of these are required in any execution context,
they should not be pushed to the server.

### Protocol Changes

The version of the ChatopsRPC protocol in use by a server is given as the
`version` field. If no version is returned, `3` is assumed.

---

## Server Implementations

 * [chatops-controller](https://github.com/github/chatops-controller) makes it easy to add CRPC endpoints to rails applications.

## Installation

In hubot project repo, run:

`npm install hubot-chatops-rpc --save`

Then add **hubot-chatops-rpc** to your `external-scripts.json`:

```json
[
  "hubot-chatops-rpc"
]
```

Create a public/private key pair for authentication:

```
ssh-keygen -t rsa -b 4096 -f crpc
```

This will create two files, `crpc` and `crpc.pub`. Use the contents of the
`crpc` file as an environment variable, `RPC_PRIVATE_KEY`. `crpc.pub`
contains a public key for use by servers.

## NPM Module

https://www.npmjs.com/package/hubot-chatops-rpc
