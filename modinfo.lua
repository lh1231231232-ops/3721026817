-- 本文件只描述模组名称、兼容性和配置界面，不包含自动盾反算法。
-- DST 会在受限环境中读取它，因此这里尽量只使用基础 Lua 语法。

--The name of the mod displayed in the 'mods' screen.
name = "自动盾反"

--A description of the mod.
description = [[
  mod用法：按左右调整识别延迟，盾反时机早了就按↑，晚了就按下，默认0.
  按z开启或者关闭
  /agronssword可以寻找艾剑
]]
author = "萌萌的新"

--A version number so you can ask people if they are running an old version of your mod.
version = "1.69" --2024.6.27日更新

--This lets other players know if your mod is out of date. This typically needs to be updated every time there's a new game update.
api_version = 6
api_version_dst = 10
priority = 0

--Compatible with both the base game and Reign of Giants
dont_starve_compatible = false
reign_of_giants_compatible = false
shipwrecked_compatible = false
dst_compatible = true

-- false + client_only_mod=true：这是本地客户端辅助，不要求服务器或其他玩家安装。
-- 真正的盾反动作仍需要连接的服务器已经启用《棱镜》。
--This lets clients know if they need to get the mod from the Steam Workshop to join the game
all_clients_require_mod = false

--This determines whether it causes a server to be marked as modded (and shows in the mod list)
client_only_mod = true

--This lets people search for servers with this mod by these tags
server_filter_tags = {}

icon_atlas = "modicon.xml"
icon = "modicon.tex"
local string = ""
local keys = { "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U",
  "V", "W", "X", "Y", "Z", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12", "LAlt", "RAlt",
  "LCTRL", "RCTRL", "LSHIFT", "RSHIFT", "TAB", "CAPSLOCK", "SPACE", "MINUS", "EQUALS", "BACKSPACE", "INSERT", "HOME",
  "DELETE", "END", "PAGEUP", "PAGEDOWN", "PRINT", "SCROLLOCK", "PAUSE", "PERIOD", "SLASH", "SEMICOLON", "LEFTBRACKET",
  "RIGHTBRACKET", "BACKSLASH", "UP", "DOWN", "LEFT", "RIGHT" }
local keylist = {}
for i = 1, #keys do
  keylist[i] = { description = keys[i], data = "KEY_" .. string.upper(keys[i]) }
end
keylist[#keylist + 1] = { description = "Disabled", data = false }
local function AddConfig(label, name, options, default, hover)
  return { label = label, name = name, options = options, default = default, hover = hover or "" }
end
-- 配置界面目前只有两个正式选项：启动热键和黑暗测试。
-- 左右方向键调帧在 modmain.lua 中直接注册，没有出现在 configuration_options。
configuration_options =
{
  AddConfig('启动热键', 'shield_start', keylist, 'KEY_Z'),
  {
    name = "darktest",
    label = "和黑暗斗智斗勇！",
    hover = "和黑暗斗智斗勇！",
    options = {
      { description = "开启", data = true },
      { description = "关闭", data = false },
    },
    default = false,
  },
}
