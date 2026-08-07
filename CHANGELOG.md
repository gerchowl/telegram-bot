# Changelog

## [0.2.0](https://github.com/gerchowl/telegram-bot/compare/v0.1.0...v0.2.0) (2026-08-03)


### ⚠ BREAKING CHANGES

* packages.telegram-bot no longer exists. Use packages.telegram-bot-rs or packages.default.
* packages.tg-send, packages.tg-bot, packages.tg-onboard and packages.tg-poll no longer exist; use packages.telegram-bot-rs or packages.default. apps.send-rs / apps.bot-rs are gone — apps.send and apps.bot are the compiled binaries.

### Features

* add compiled Rust (v2) implementation of tg-send + tg-bot ([047edbe](https://github.com/gerchowl/telegram-bot/commit/047edbe41acc1e9132f523a47e76a3745adb82eb))
* **docs:** generate the drifting doc surfaces, empty the allowlist ([#44](https://github.com/gerchowl/telegram-bot/issues/44)) ([20a3b27](https://github.com/gerchowl/telegram-bot/commit/20a3b2734ccc6bf89e22938f55ad5eb6e7600602)), closes [#23](https://github.com/gerchowl/telegram-bot/issues/23) [#24](https://github.com/gerchowl/telegram-bot/issues/24)
* drop the packages.telegram-bot compatibility alias ([#49](https://github.com/gerchowl/telegram-bot/issues/49)) ([7c5f43e](https://github.com/gerchowl/telegram-bot/commit/7c5f43e281f43def85c243c12f756aa85edf7fdf))
* expose tg-mcp as the `mcp` flake app ([#35](https://github.com/gerchowl/telegram-bot/issues/35)) ([494072c](https://github.com/gerchowl/telegram-bot/commit/494072cd338f659e7f0f58c86d1b3ea36234168b))
* **hm:** commands attrset, launchd support, and a module-evaluation gate ([#39](https://github.com/gerchowl/telegram-bot/issues/39)) ([97d4954](https://github.com/gerchowl/telegram-bot/commit/97d495415d7912801244824fb446034e2e56167e)), closes [#18](https://github.com/gerchowl/telegram-bot/issues/18) [#17](https://github.com/gerchowl/telegram-bot/issues/17) [#37](https://github.com/gerchowl/telegram-bot/issues/37)
* make the compiled Rust implementation canonical, remove bash ([#38](https://github.com/gerchowl/telegram-bot/issues/38)) ([9647b26](https://github.com/gerchowl/telegram-bot/commit/9647b260185ebaf77f68d80c95eacca657aa866a)), closes [#22](https://github.com/gerchowl/telegram-bot/issues/22)
* **mcp:** authenticate the TCP transport, and harden `ask` ([#46](https://github.com/gerchowl/telegram-bot/issues/46)) ([cf8659e](https://github.com/gerchowl/telegram-bot/commit/cf8659e7b4099411a5e13d450c155535f85bb98b)), closes [#43](https://github.com/gerchowl/telegram-bot/issues/43)
* **mcp:** latch answered asks (toast + edit message, strip buttons) ([b727500](https://github.com/gerchowl/telegram-bot/commit/b727500f955fe46635e3b6a04238a116737e8f21))
* **mcp:** latch by check-marking the chosen button (keep buttons) ([fcd01ba](https://github.com/gerchowl/telegram-bot/commit/fcd01bab8d10801f308d58812866d51e0655ab8b))
* **mcp:** send_file — agents can deliver files, not just text ([#42](https://github.com/gerchowl/telegram-bot/issues/42)) ([d108fbc](https://github.com/gerchowl/telegram-bot/commit/d108fbc706337d7641ba291990e2e1f5c10f49ec)), closes [#36](https://github.com/gerchowl/telegram-bot/issues/36)
* **mcp:** TCP transport for central mode (tailnet) ([f578672](https://github.com/gerchowl/telegram-bot/commit/f57867295a0964eaf752868eb5b47153100afb48))
* **mcp:** tg-mcp — MCP server + reply-routing daemon ([657daf8](https://github.com/gerchowl/telegram-bot/commit/657daf8f5f54655c610dffaf8c339e8e99b3d975))
* per-command parse mode + plain-text fallback ([#9](https://github.com/gerchowl/telegram-bot/issues/9)) ([7364e0e](https://github.com/gerchowl/telegram-bot/commit/7364e0eaccb52f9c7549ec4485cc0ea58b2cffe0))
* **tg-bot:** /help lists command descriptions from `# desc:` ([#40](https://github.com/gerchowl/telegram-bot/issues/40)) ([a68f332](https://github.com/gerchowl/telegram-bot/commit/a68f332f52b38989f20106e95a45445017bc2f1a)), closes [#19](https://github.com/gerchowl/telegram-bot/issues/19)
* **tg-bot:** auto-publish command menu via setMyCommands on startup ([#15](https://github.com/gerchowl/telegram-bot/issues/15)) ([98f7319](https://github.com/gerchowl/telegram-bot/commit/98f7319ef2d5c44a8a8f5b648ca44515fbcdb63a))
* **tg-bot:** auto-register the / menu via setMyCommands from # desc: lines ([#16](https://github.com/gerchowl/telegram-bot/issues/16)) ([a8d9803](https://github.com/gerchowl/telegram-bot/commit/a8d98036fe5d87b5485a0406e590f3d636699f82))
* **tg-bot:** command replies can attach media via a stdout sentinel ([#41](https://github.com/gerchowl/telegram-bot/issues/41)) ([b8128f8](https://github.com/gerchowl/telegram-bot/commit/b8128f8ef6a8ba4e329cf3ac16a2ec50524743a1)), closes [#20](https://github.com/gerchowl/telegram-bot/issues/20)
* tg-poll (sendPoll) + capture non-anonymous poll answers ([#10](https://github.com/gerchowl/telegram-bot/issues/10)) ([024558d](https://github.com/gerchowl/telegram-bot/commit/024558d88edd6b9670c349bc87a63a001186c7e9))


### Bug Fixes

* fail loud on token-resolution / auth errors ([#8](https://github.com/gerchowl/telegram-bot/issues/8)) ([a3bca9e](https://github.com/gerchowl/telegram-bot/commit/a3bca9ea40b4bda16d593a36ba7018f1b239bac2))
* review hardening — AF_UNIX, multipart filename, pinned actions ([f131da3](https://github.com/gerchowl/telegram-bot/commit/f131da3cdd856917123c4552168e3fca4733287e))
* **rust:** rustls TLS + token redaction + parse-mode/poll parity; TLS smoke ([#27](https://github.com/gerchowl/telegram-bot/issues/27)) ([290be4a](https://github.com/gerchowl/telegram-bot/commit/290be4a82949351c21ac84ea5a226c7affe91b0b))
* **tg-bot:** stop a leaked grandchild wedging the poll loop forever ([#48](https://github.com/gerchowl/telegram-bot/issues/48)) ([650fc2a](https://github.com/gerchowl/telegram-bot/commit/650fc2a6b60730b9e0e3b8e5d07af0e0eaf949c9)), closes [#47](https://github.com/gerchowl/telegram-bot/issues/47)
