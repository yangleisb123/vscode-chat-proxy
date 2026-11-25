// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "1123Javayanglei/vscode-chat-proxy"

version = "0.9.1"

readme = "README.mbt.md"

repository = "https://github.com/yangleisb123/vscode-chat-proxy"

license = "Apache-2.0"

keywords = [ "openai", "proxy", "chat-completions", "vscode" ]

preferred_target = "native"

supported_targets = "+native+js"

description = "Local HTTP proxy that ensures Chat Completions system messages start with the required VSCode AI-assistant sentence"

import {
  "moonbitlang/async@0.22.10",
  "moonbit-community/rabbita@0.17.0",
  "spectacleCase/dotenv@0.1.0",
  "moonbitlang/moonback@0.8.11",
}
