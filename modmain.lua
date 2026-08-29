--[[
===============================================================================
自动盾反（客户端模组）代码阅读总览
===============================================================================

这份文件没有实现“盾牌如何免伤”。真正的盾反状态、伤害拦截和反击效果由
《棱镜》服务器端提供。本模组负责在客户端做以下事情：

1. 每帧扫描玩家附近的实体；
2. 用 prefab（实体种类）和当前动画名查询 Autoshield.targettable；
3. 检查动画帧、攻击目标、距离、朝向和网络延迟；
4. 判定攻击即将命中时，自动装备盾牌并发送棱镜的举盾动作 RPC；
5. 对少数其他人物/模组，用翻滚等动作代替盾反。

建议按以下顺序阅读：
  Autoshield.targettable      攻击帧数据库
  CheckTargetHitFrame()       单个敌人的威胁判定
  needshield()                搜索附近所有候选实体
  DoShield()                  整理物品并发送举盾动作
  start()/stop()/autoshield() 自动检测线程及开关

本次添加的长注释只解释原代码，不改变任何数值和执行逻辑。
===============================================================================
]]

-- 将模组环境的缺失字段转发到 GLOBAL，后面可以直接写 ThePlayer、ACTIONS 等，
-- 不必每次都写 GLOBAL.ThePlayer、GLOBAL.ACTIONS。
GLOBAL.setmetatable(env, {
  __index = function(t, k)
    return GLOBAL.rawget(GLOBAL, k)
  end
})
-- 按职责拆分的辅助函数表；它们不是游戏组件，只是本文件内部的命名空间。
local MOD_util = {}    -- 模组检测、聊天命令等
local ENT_util = {}
local TAB_util = {}
local INV_util = {}
local PLAYER_util = {}
local GAME_util = {}
local EQUIP_util = {}
local EquipSlot = require("equipslotutil")
function EQUIP_util:ToID(name)
  return EquipSlot.ToID(name)
end

-- 注册只在本地执行的斜杠命令。文件末尾用它注册了 /agronssword。
function MOD_util:AddUserCommand(command_string, params_table, client_command_fn)
  local command_data = {
    name = command_string,
    prettyname = nil,
    desc = nil,
    permission = COMMAND_PERMISSION.USER,
    slash = true,
    usermenu = false,
    servermenu = false,
    params = params_table,
    localfn = client_command_fn
  }
  AddUserCommand(command_data.name, command_data)
end

-- HUD 正常且没有聊天框/控制台等输入焦点时，才允许响应快捷键。
function GAME_util:InGame()
  return ThePlayer and ThePlayer.HUD and not ThePlayer.HUD:HasInputFocus()
end

-- 优先让角色说话；没有 talker 组件时退回到聊天命令反馈。
function PLAYER_util:Say(str)
  if ThePlayer and ThePlayer.components.talker then
    ThePlayer.components.talker:Say(str)
  else
    ChatHistory:SendCommandResponse('解控关闭')
  end
end

-- 判断物品 v 是否满足 prefab、必须标签、排除标签和额外回调条件。
-- FindInInv() 使用它统一过滤装备栏、主物品栏和打开的容器。
local function isneed(v, prefabs, tags, nottags, fn)
  --[[ print((not prefabs or type(prefabs) == 'string' and v.prefab == prefabs
            or type(prefabs) == 'table' and table.contains(prefabs, v.prefab)),
        (not tags or type(tags) == 'string' and v:HasTag(tags) or type(tags) == 'table' and v:HasOneOfTags(tags)),
        (not nottags or type(nottags) == 'string' and not v:HasTag(nottags) or type(nottags) == 'table'
            and not v:HasOneOfTags(nottags)), (not fn or fn(v))) ]]
  if (not prefabs or type(prefabs) == 'string' and v.prefab == prefabs
        or type(prefabs) == 'table' and table.contains(prefabs, v.prefab))
      and (not tags or type(tags) == 'string' and v:HasTag(tags) or type(tags) == 'table' and v:HasOneOfTags(tags))
      and (not nottags or type(nottags) == 'string' and not v:HasTag(nottags) or type(nottags) == 'table'
        and not v:HasOneOfTags(nottags))
      and (not fn or fn(v)) then
    return true
  end
end
-- 在本地玩家可见的库存中查找第一件满足条件的物品。
-- 返回值：物品实体、槽位编号、容器实体（主物品栏的容器为 nil）。
function INV_util:FindInInv(prefabs, tags, nottags, fn, notsearchtab) --如果都是nil会返回一个身上的物品
  if not notsearchtab or not notsearchtab.equips then
    for k, v in pairs(ThePlayer.replica.inventory:GetEquips()) do
      if isneed(v, prefabs, tags, nottags, fn) then
        return v, k, nil
      end
    end
  end
  if not notsearchtab or not notsearchtab.items then
    for k, v in pairs(ThePlayer.replica.inventory:GetItems()) do
      if isneed(v, prefabs, tags, nottags, fn) then
        return v, k, nil
      end
    end
  end
  if not notsearchtab or not notsearchtab.items then
    --[[  local active = ThePlayer.replica.inventory:GetActiveItem()
        if isneed(active, prefabs, tags, nottags, fn) then
            return active
        end ]]
  end
  if not notsearchtab or not notsearchtab.container then
    for k, v in pairs(ThePlayer.replica.inventory:GetOpenContainers() or {}) do
      if k and k.replica and k.replica.container then --如果是空表不知道k是不是nil??以防万一还是判定空
        for kkk, vvv in pairs(k.replica.container:GetItems()) do
          if isneed(vvv, prefabs, tags, nottags, fn) then
            return vvv, kkk, k
          end
        end
      end
    end --Inventory:GetOverflowContainer()
  elseif not notsearchtab or not notsearchtab.backpack then
    local backpack = ThePlayer.replica.inventory:GetOverflowContainer()
    if backpack then
      for kkk, vvv in pairs(backpack:GetItems()) do
        if isneed(vvv, prefabs, tags, nottags, fn) then
          return vvv, kkk, backpack.inst
        end
      end
    end
  end
end

-- GetHistoryData() 的第二个返回值是当前动画名，例如 atk、atk_pre。
-- 自动盾反依赖动画名在 targettable 中查表。
function ENT_util:GetAnimation(ent)
  if ent == nil then return end
  local a, b, c, d, e, f = ent.AnimState:GetHistoryData()
  return b
end

-- 将一个表的值追加到另一个表。needshield() 用它合并两组扫描结果。
function TAB_util:InsertTable(destTable, srcTable)
  if srcTable and type(srcTable) == 'table' and next(srcTable) then
    for _, value in pairs(srcTable) do
      table.insert(destTable, value)
    end
  end
end

-- 在实体调试字符串中查找任意给定片段；主要用于兼容没有直接客户端字段的状态。
function ENT_util:CheckDebugString(ent, ...)
  if ent == nil then return end
  local str = ent.entity
      and ent.entity:GetDebugString()
  for k, v in pairs({ ... }) do
    if type(v) == "table" then
      for key, value in pairs(v) do
        if ENT_util:CheckDebugString(ent, value) then
          return true
        end
      end
    elseif str and string.find(str, v) then
      return true
    end
  end
end

-- 配置项既可以是固定数字，也可以是动态计算函数；这里把两种写法统一成数值。
function ENT_util:FnOrNum(a, ...)
  if type(a) == "function" then
    return a(...)
  else
    return a
  end
end

-- 计算 target1 正面方向与“指向 target2 的方向”的夹角（0~180 度）。
-- 数值越小，说明攻击者越正对玩家。
function ENT_util:GetAngle(target1, target2)
  if not target1 then return end
  if not target2 then return target1:GetRotation() end
  local tx, ty, tz = target1:GetPosition():Get()
  local px, py, pz = target2:GetPosition():Get()
  if tx == px and tz == pz then
    tx = tx + 0.1
    tz = tz + 0.1
  end
  local heading = -target1:GetRotation()
  local pa = math.atan2(pz - tz, px - tx) / DEGREES
  local result = heading - pa --0 - 360
  result = math.abs(result)
  if result > 180 then
    result = 360 - result
  end
  return result
end

-- 通过显示名称或 Workshop 标识检查某个模组是否启用。
-- 自动盾反用它判断棱镜及少量兼容模组是否存在。
function MOD_util:CheckMod(name)
  for k, v in pairs(ModManager.mods) do
    local modname = v.modinfo.name
    if type(name) == "string" then
      if modname == name or modname and string.find and string.find(modname, name) or KnownModIndex:IsModEnabledAny(name) then
        return true
      end
    elseif type(name) == "table" then
      for _, checkname in pairs(name) do
        if modname == checkname or modname and string.find and string.find and string.find(modname, checkname) or KnownModIndex:IsModEnabledAny(checkname) then
          return true
        end
      end
    end
  end
end

-- modinfo.lua 保存的是 "KEY_Z" 这样的字符串，这里将其转换成实际按键常量。
function GetKeyFromConfig(name)
  local a = GetModConfigData(name)
  return a and rawget(GLOBAL, a)
end
-- 为鼠标上的 active item 寻找临时空格。
-- 返回槽位和容器；主物品栏容器返回 nil，背包则返回背包实体。
function INV_util:FindEmptySlot(con, excludepos, excludecon)
  if not con or con == ThePlayer then
    local inventory = ThePlayer.replica.inventory
    if inventory:IsFull() then
      local backpack = inventory:GetOverflowContainer()
      if backpack and not backpack:IsFull() then
        for i = 1, backpack:GetNumSlots() do
          if not backpack:GetItemInSlot(i)
              and (i ~= excludepos or backpack.inst ~= excludecon) then
            return i, backpack.inst
          end
        end
      end
    else
      for i = 1, inventory:GetNumSlots() do
        if not inventory:GetItemInSlot(i)
            and (i ~= excludepos or nil ~= excludecon) then
          return i
        end
      end
      local backpack = inventory:GetOverflowContainer()
      if backpack and not backpack:IsFull() then
        for i = 1, backpack:GetNumSlots() do
          if not backpack:GetItemInSlot(i)
              and (i ~= excludepos or backpack.inst ~= excludecon) then
            return i, backpack.inst
          end
        end
      end
    end
  else
    local backpack = con.replica.container
    if not backpack then return end
    for i = 1, backpack:GetNumSlots() do
      if not backpack:GetItemInSlot(i)
          and (i ~= excludepos or backpack.inst ~= excludecon) then
        return i, backpack.inst
      end
    end
  end
end
-- 自动盾反运行状态。这里的数据贯穿检测、调参和动作执行三个阶段。
local Autoshield = {}
Autoshield.author = true -- true：玩家受击时把附近已适配实体的动画打印到控制台，便于校准新攻击
--如果你想自己加mod生物的盾反，就打开把anchor改成true，在那个生物旁边待着吸引仇恨，看看对应的动画，收击的那一帧提前六七帧就行。
Autoshield.carneymodnrpc = nil --缓存卡尼猫闪避 RPC，避免每次触发都重新查找
Autoshield.characterdelay = 0 --某些人物动作的专用帧修正，例如卡尼猫设为 -2
Autoshield.shielddelay = 0 --玩家用左右方向键调整的全局帧偏移：正数更晚，负数更早
Autoshield.loopticks = {} --记录持续/循环攻击已经维持了多少检测帧
Autoshield.printflag = {} --预留的打印状态表
Autoshield.behitprint = {} --防止一次受击过程中重复打印同一个实体动画
Autoshield.darktest = GetModConfigData('darktest')

-- 创建一条攻击配置的简写函数。targettable 中也大量直接写同结构的 Lua 表。
local function creattable(startframe, duration, isaoeatk, facingcheck, distcompense)
  return {
    startframe = startframe,
    duration = duration,
    isaoeatk = isaoeatk,
    facingcheck = facingcheck,
    distcompense = distcompense
  }
end
--[[
攻击帧数据库 targettable
-------------------------
第一层 key：实体 prefab，例如 spider、deerclops。
第二层 key：客户端看到的动画名，例如 atk、atk_pre。
第二层 value：本动画的判定规则，常用字段如下：

  startframe       开始触发的动画帧。通常已经比真正命中帧提前约 6~8 帧。
  duration         判定窗口长度，未写时默认 5 帧。
  isaoeatk         true 表示范围攻击，不要求 combat target 必须是本地玩家。
  facingcheck      要求攻击者面向玩家；数字表示允许的最大夹角。
  distcompense     在 combat 攻击距离基础上增加/减少的距离修正。
  realdist         不使用 combat 攻击距离，直接指定固定检测距离。
  startframe 函数  根据实体状态动态计算开始帧。
  checkpawloop     为循环蓄力动作累计持续帧数。
  doshieldfn       完全自定义的“是否应该防御”判断。
  cancelshieldfn   即使其他条件成立，也可通过回调取消本次触发。

示例：['pigman']['atk'] = { startframe = 6 }
含义是猪人播放 atk 且动画到第 6 帧后，进入最多 5 帧的触发窗口。

这个表占据文件的大部分篇幅，但它只是数据，不是 200 多套不同算法。
]]
--通过prefab的缓存来访问targettable
Autoshield.targettable = {

  ['alterguardian_phase1'] = {
    ['tantrum_loop'] = { startframe = 1, distcompense = -11 },
    ['roll_loop'] = { facingcheck = 20, duration = 100, realdist = 4 },
  },
  ['alterguardian_phase2'] = {
    ['attk_chop'] = { isaoeatk = true, startframe = 12 },
    ['attk_spin_pre'] = { isaoeatk = true, startframe = 23 },
    ['attk_stab_pre'] = { isaoeatk = true, startframe = 16 },
    ['attk_spin_loop'] = { isaoeatk = true, duration = 100 },
  },
  ['alterguardian_phase3'] = {
    ['attk_swipe'] = { isaoeatk = true, startframe = 33, duration = 100 },
    ['attk_beam'] = { isaoeatk = true, startframe = 29, duration = 100 },
    ['attk_stab'] = { isaoeatk = true, startframe = 21, duration = 100, distcompense = -11 },
  },
  ['shadowthrall_hands'] = { ['run_loop'] = { startframe = 5, distcompense = 4 }, },
  ['shadowthrall_horns'] = {
    ['slap'] = { startframe = 7, duration = 100 },
    ['jump'] = { startframe = 23 },
  },
  ['shadowthrall_wings'] = { ['cast'] = { startframe = 48 }, },
  ['bearger'] = {
    ['atk'] = { isaoeatk = true, startframe = 25, distcompense = 2 }, --熊32
    ['ground_pound'] = {
      isaoeatk = true,
            startframe = function(target)                                                                --18 19 24
        local dist = math.sqrt(distsq(target:GetPosition(), ThePlayer:GetPosition())) or 0
        local range = target.replica.combat and target.replica.combat:GetAttackRangeWithWeapon() --8
        local result = 16 +                                                                      --6
            10 * (dist - ThePlayer:GetPhysicsRadius(0) - target:GetPhysicsRadius(0)) /
            (range)
        -- if dist > 4.5 then return 18 end
        return result
      end,
      distcompense = 2
    },
  },
  ['mutatedbearger'] = {
    ['ground_pound'] = {
            startframe = function(target)                                                                --18 19 24
        local dist = math.sqrt(distsq(target:GetPosition(), ThePlayer:GetPosition())) or 0
        local range = target.replica.combat and target.replica.combat:GetAttackRangeWithWeapon() --8
        local result = 16 +                                                                      --6
            10 * (dist - ThePlayer:GetPhysicsRadius(0) - target:GetPhysicsRadius(0)) /
            (range)
        -- if dist > 4.5 then return 18 end
        return result
      end,
      distcompense = 2
    },                                                 --拍地32远距离26
    --['ground_pound'] = {  startframe = 16, distcompense = -2.1 }, --熊拍地21近距离
    ['atk1'] = { startframe = 25, distcompense = 2 },  --僵尸熊32
    ['atk1a'] = { startframe = 21, distcompense = 2 }, --僵尸熊28
    ['atk2'] = { startframe = 21, distcompense = 2 },  --僵尸熊28
    ['butt'] = { distcompense = 5 },
  },
  ['deerclops'] = {
    ['atk'] = { isaoeatk = true, startframe = 27 }, --巨鹿34 35
    ['atk2'] = {
      isaoeatk = true,
            startframe = function(target)                                                                --18 19 24
        local dist = math.sqrt(distsq(target:GetPosition(), ThePlayer:GetPosition())) or 0
        local range = target.replica.combat and target.replica.combat:GetAttackRangeWithWeapon() --8
        local result = 13 +                                                                      --6
            4 * (dist - ThePlayer:GetPhysicsRadius(0) - target:GetPhysicsRadius(0)) /
            (range)
        return result
      end,
    },
  },
  ['mutateddeerclops'] = {
    ['atk'] = { startframe = 27 },                      --巨鹿34 35
    ['throw'] = { startframe = 54, distcompense = 10 }, --僵尸巨鹿61
    ['throw_2'] = { startframe = 54, distcompense = 10 },
  },
  ['dragonfly'] = {
    ['atk'] = { startframe = 8 },
    ['taunt_pre'] = { isaoeatk = true, startframe = 15, duration = 10, distcompense = -2.5 },
    ['taunt'] = { isaoeatk = true, duration = 15 },
  },
  ['malbatross'] = { ['atk'] = { startframe = 22 }, },

  ['beequeen'] = { ['atk'] = { startframe = 7 }, },
  ['klaus'] = { ['attack_doubleclaw'] = { startframe = 10, duration = 10 }, ['attack_chomp'] = { startframe = 28, distcompense = 10 }, },
  ['minotaur'] = {
    ['bite'] = { startframe = 9 }, --犀牛咬人15 16
    ['jump_atk_loop'] = { isaoeatk = true, startframe = 9, distcompense = 10 },
    ['atk'] = { facingcheck = 20, duration = 100, realdist = 4 },
    ['paw_loop'] = { checkpawloop = true, time = 41, distance = 2.5 }, --pawloop
    ['allanim'] = { checkpawloop = false, }
  },
  ['rook'] = {
    ['paw_loop'] = { checkpawloop = true, time = 41 - 14, distance = 2.5 },
    ['atk'] = {isaoeatk = true,facingcheck = 75,duration = 100,realdist = 3,},
    ['allanim'] = { checkpawloop = false, }
  },
  ['rook_nightmare'] = {
    ['paw_loop'] = { checkpawloop = true, time = 41 - 14, distance = 2.5 },
    ['atk'] = {isaoeatk = true,facingcheck = 75,duration = 100,realdist = 3,},
    ['allanim'] = { checkpawloop = false, }
  },

  ['stalker'] = {
    ['attack'] = { startframe = 25 }, --骨架打人（包括三种骨架）32
    ['attack1'] = { startframe = 19 },
  },
  ['stalker_atrium'] = {
    ['attack'] = { startframe = 25 },  --骨架打人（包括三种骨架）32
    ['attack1'] = { startframe = 19 }, --骨牢26
    ['spike'] = { startframe = 42 },
  },
  ['shadow_knight'] = { ['atk_pre'] = { startframe = 12, distcompense = 10 }, },
  ['shadow_bishop'] = {
    ['atk_side_loop_pre'] = {
      isaoeatk = true,
      hitrange = 1.75,
      distcompense = -2, --ATTACK_RANGE = {4, 6, 8}HIT_RANGE = 1.75,
      cancelshieldfn = function()
        if string.find(ThePlayer.entity:GetDebugString(), 'toolpunch') and (ThePlayer.AnimState:GetCurrentAnimationFrame() or 0) <= 50 then
          return true
        end
        return false
      end
    },
    ['atk_side_loop'] = {
      isaoeatk = true,
      startframe = 0,
      duration = 200,
      distcompense = -2,
      cancelshieldfn = function() --loop期间不能盾的太快了，会一直挨打
        if string.find(ThePlayer.entity:GetDebugString(), 'hit') and (ThePlayer.AnimState:GetCurrentAnimationFrame() or 0) <= 7
            or string.find(ThePlayer.entity:GetDebugString(), 'toolpunch') and (ThePlayer.AnimState:GetCurrentAnimationFrame() or 0) <= 50
            or string.find(ThePlayer.entity:GetDebugString(), 'idle_') and (ThePlayer.AnimState:GetCurrentAnimationFrame() or 0) <= 2 then
          return true
        end
        return false
      end
    },
  },
  ['shadow_rook'] = { ['teleport_atk'] = { isaoeatk = true, startframe = 9, distcompense = -4 }, },
  ['leif'] = { ['atk'] = { startframe = 17 }, },
  ['leif_sparse'] = { ['atk'] = { startframe = 17 }, },
  ['lordfruitfly'] = { ['atk'] = { startframe = 2 }, },
  ['spiderqueen'] = {
    ['atk'] = { startframe = 21 }, --蜘蛛女王28
  },
  ['warg'] = { ['atk'] = { startframe = 5 }, },
  ['mutatedwarg'] = {
    ['atk'] = { startframe = 5 },
    ['atk_breath_pre'] = { startframe = 29 },
    ['atk_breath_loop'] = { duration = 100 },
  },
  ['claywarg'] = { ['atk'] = { startframe = 3 }, },
  ['gingerbreadwarg'] = { ['atk'] = { startframe = 5 }, },
  ['spat'] = { ['strike'] = {}, ['snot'] = { startframe = 23, distcompense = 20 }, },
  ['daywalker'] = { ['atk3'] = { startframe = 3, distcompense = 20 }, ['atk_slam'] = { startframe = 20 }, },
  ['daywalker2'] = {
    ['atk_object'] = { startframe = 8, },
    ['tackle_pre'] = { startframe = 2, },
    ['laser_pst'] = { startframe = 0, },
  },
  ['moose'] = { ['atk'] = { startframe = 13 }, ['hopatk_loop'] = { startframe = 17, distcompense = 20 }, },
  ['antlion'] = { ['cast_pre'] = { startframe = 27, distcompense = 20 }, },
  ['eyeofterror'] = {
    ['chomp'] = { isaoeatk = true, startframe = 17 },
    ['charge_pre'] = { isaoeatk = true, facingcheck = 20, startframe = 30, duration = 100, realdist = 4 },
    ['charge_loop'] = { isaoeatk = true, facingcheck = 20, duration = 100, realdist = 6 },
  },
  ['twinofterror1'] = {
    ['chomp'] = { isaoeatk = true, startframe = 17 },
    ['charge_pre'] = { isaoeatk = true, facingcheck = 20, startframe = 30, duration = 100, realdist = 4 },
    ['charge_loop'] = { isaoeatk = true, facingcheck = 20, duration = 100, realdist = 6 },
  },
  ['twinofterror2'] = {
    ['chomp'] = { isaoeatk = true, startframe = 17 },
    ['charge_pre'] = { isaoeatk = true, facingcheck = 20, startframe = 30, duration = 100, realdist = 4 },
    ['charge_loop'] = { isaoeatk = true, facingcheck = 20, duration = 100, realdist = 6 },
  },
  ['toadstool'] = { ['attack_pound_pre'] = { startframe = 33 }, },
  ['toadstool_dark'] = { ['attack_pound_pre'] = { startframe = 33 }, },
  ['mushroombomb'] = { ['explode_pre'] = { isaoeatk = true, startframe = 2, distcompense = 10 }, },
  ['mushroombomb_dark'] = { ['explode_pre'] = { isaoeatk = true, startframe = 2, distcompense = 10 }, },
  ['deciduous_root'] = { ['atk'] = { isaoeatk = true, }, },
  ['birchnutdrake'] = { ['atk'] = { startframe = 5 }, },
  ['pigman'] = { ['atk'] = { startframe = 6 }, ['were_atk'] = { duration = 3 }, ['were_atk_pre'] = { startframe = 12 }, },
  ['moonpig'] = { ['were_atk'] = { duration = 3 }, ['were_atk_pre'] = { startframe = 12 }, },
  ['pigguard'] = { ['atk'] = { startframe = 6 }, },
  ['merm'] = { ['atk'] = { startframe = 6 }, },
  ['mermguard'] = { ['atk'] = { startframe = 6 }, },
  ['bunnyman'] = { ['atk'] = { startframe = 6 }, },
  ['knight'] = { ['atk'] = { startframe = 10 }, },
  ['knight_nightmare'] = { ['atk'] = { startframe = 10 }, },
  ['bishop'] = { ['atk'] = { startframe = 20, distcompense = 20 }, ['atk2_loop'] = {isaoeatk = true,startframe = 14,facingcheck = 20,distcompense = 20,},},
  ['bishop_nightmare'] = { ['atk'] = { startframe = 20, distcompense = 20 }, ['atk2_loop'] = {isaoeatk = true,startframe = 14,facingcheck = 20,distcompense = 20,}, },
  ['archive_centipede'] = {
    ['atk'] = { startframe = 3 },
    ['atk_aoe'] = { startframe = 19 },
    ['atk_roll_loop'] = { facingcheck = 20, duration = 100, realdist = 5 },
  },
  ['spider'] = {
    ['atk'] = { startframe = 17 },
    ['warrior_atk'] = { startframe = 13, distcompense = 10 },
  },
  ['spider_warrior'] = {
    ['atk'] = { startframe = 17 },
    ['warrior_atk'] = { startframe = 13, distcompense = 10 },
  },
  ['spider_hider'] = { ['atk'] = { startframe = 19 }, },
  ['spider_spitter'] = {
    ['spit'] = { startframe = 22, distcompense = 20 },
    ['atk'] = { startframe = 19 },
  },
  ['spider_dropper'] = {
    ['atk'] = { startframe = 17 },
    ['warrior_atk'] = { startframe = 13, distcompense = 10 },
  },
  ['spider_moon'] = { ['atk'] = { startframe = 19 }, },
  ['hound'] = { ['atk_pre'] = { startframe = 9 }, },
  ['warglet'] = { ['atk_pre'] = { startframe = 9 }, },
  ['moonhound'] = { ['atk_pre'] = { startframe = 9 }, },
  ['firehound'] = { ['atk_pre'] = { startframe = 9 }, },
  ['icehound'] = { ['atk_pre'] = { startframe = 9 }, },
  ['mutatedhound'] = { ['atk_pre'] = { startframe = 9 }, },
  ['clayhound'] = { ['atk_pre'] = { startframe = 9 }, },
  ['frog'] = { ['atk'] = { startframe = 3 }, },
  ['catcoon'] = {
    ['atk'] = { startframe = 9 },
    ['jump_atk'] = { startframe = 13, distcompense = 10 },
  },
  ['bat'] = { ['atk'] = { isaoeatk = true, startframe = 3 }, },
  ['shark'] = { ['attack'] = { startframe = 5, duration = 10 }, },
  ['tallbird'] = { ['atk_pre'] = { startframe = 6 }, },
  ['teenbird'] = { ['atk_pre'] = { startframe = 6 }, },
  ['penguin'] = {
    ['atk'] = { startframe = 3 },
    ['slide_bounce'] = { isaoeatk = true, facingcheck = 20, duration = 100, realdist = 4 },
    ['slide_loop'] = { isaoeatk = true, facingcheck = 20, duration = 100, realdist = 4 },
  },
  ['mutated_penguin'] = {
    ['atk'] = { startframe = 3 },
    ['slide_bounce'] = { isaoeatk = true, facingcheck = 20, duration = 100, realdist = 4 },
    ['slide_loop'] = { isaoeatk = true, facingcheck = 20, duration = 100, realdist = 4 },
  },
  ['beefalo'] = { ['atk'] = { startframe = 3 }, },
  ['koalefant_summer'] = { ['atk'] = { startframe = 3 }, },
  ['koalefant_winter'] = { ['atk'] = { startframe = 3 }, },
  ['lightninggoat'] = { ['atk'] = { startframe = 5 }, },
  ['tentacle_pillar_arm'] = { ['atk_loop'] = {}, },
  ['tentacle'] = { ['atk_loop'] = {}, },
  ['bigshadowtentacle'] = { ['atk_loop'] = {}, },
  ['bee'] = { ['atk'] = { startframe = 10 }, },
  ['killerbee'] = { ['atk'] = { startframe = 10 }, },
  ['mosquito'] = { ['atk'] = { startframe = 8 }, },
  ['fruitdragon'] = { ['attack'] = { startframe = 15 }, },
  ['eyeplant'] = { ['atk'] = { startframe = 8 }, },
  ['monkey'] = { ['atk'] = { startframe = 10 }, },
  ['slurtle'] = { ['atk'] = { startframe = 3 }, },
  ['rocky'] = { ['atk'] = { startframe = 13 }, },
  ['worm'] = { ['atk'] = { startframe = 19 }, },
  ['krampus'] = { ['atk'] = { duration = 3 }, ['atk_pre'] = { startframe = 13 }, },
  ['trap_starfish'] = { ['trap'] = { isaoeatk = true, startframe = 0, distcompense = 5 }, },
  ['waterplant'] = { ['attack'] = { startframe = 30 }, },
  ['crawlingnightmare'] = { ['atk'] = { startframe = 2 }, },
  ['nightmarebeak'] = { ['atk'] = { startframe = 4 }, },
  ['ruinsnightmare'] = {['atk'] = {startframe = 5,},},-- 暗影潜伏梦魇：普通近战攻击
  ['ruinsnightmare_horn_attack'] = {['horn_atk'] = {isaoeatk = true,startframe = 0,duration = 100,realdist = 4,},},
  ['terrorbeak'] = { ['atk'] = { startframe = 4 }, },
  ['crawlinghorror'] = { ['atk'] = { startframe = 2 }, },
  ['oceanhorror'] = { ['atk'] = { startframe = 1 }, },
  ['fused_shadeling'] = { ['attack'] = { startframe = 7 }, },
  ['deer'] = { ['atk'] = { startframe = 5 }, },
  ['deer_red'] = { ['atk'] = { startframe = 5 }, },
  ['deer_blue'] = { ['atk'] = { startframe = 5 }, },
  ['lavae'] = { ['atk'] = { startframe = 2 }, },
  ['beeguard'] = { ['atk'] = { startframe = 5 }, },
  ['lunarthrall_plant'] = {
    ['atk_med'] = {}, --3
    ['atk_short'] = {},
    ['atk_tall'] = {},
  },
  ['lunarthrall_plant_vine_end'] = { ['atk'] = { startframe = 10 }, },
  ['molebat'] = { ['attack'] = { startframe = 3 }, },
  ['grassgator'] = { ['atk'] = { startframe = 3 }, },
  ['powder_monkey'] = {
    ['unequipped_atk'] = { startframe = 7 }, --火药猴（无装备）14
    ['atk'] = { startframe = 7 },
  },
  ['eyeofterror_mini'] = {
    ['atk'] = {}, --眼镜怪4
    ['atk_pre'] = { startframe = 7 },
  },
  ['buzzard'] = { ['atk'] = { startframe = 9 }, },
  ['mossling'] = { ['spin_pre'] = { startframe = 8 }, },
  ['bird_mutant'] = { ['attack'] = { isaoeatk = true, startframe = 1 }, },
  ['bird_mutant_spitter'] = { ['attack'] = { isaoeatk = true, startframe = 38, distcompense = 5 }, },
  ['walrus'] = { ['atk_dart'] = { startframe = 17 }, },
  ['sharkboi'] = {
    ['icedive_jump'] = { startframe = 12 }, --20
    ['atk1'] = { startframe = 9 },          --16
    ['atk3'] = { startframe = 4 },          --12
    ['torpedo_pre'] = { startframe = 29 },
  },
  ['fused_shadeling_bomb_ball'] = { ['ball_grow'] = { isaoeatk = true, startframe = 31, distcompense = 5 }, },
  ['fused_shadeling_quickfuse_bomb'] = { ['ball_grow'] = { isaoeatk = true, startframe = 30, distcompense = 5 }, },
  
  ['crabking_mob'] = {['atk1'] = {startframe = 11,},},
  ['crabking_mob_knight'] = {['atk1'] = {startframe = 11,},['atk_loop'] = {isaoeatk = true,startframe = 0,duration = 100,realdist = 2.1,},},
  --玩家
  ['wilson'] = {
    ['atk_pillow_pre'] = {
      doshieldfn = function(target) --TheNet:GetPVPEnabled()
        if target ~= ThePlayer then
          local nowdist = math.sqrt(distsq(target:GetPosition(), ThePlayer:GetPosition()))
          local realdist = 4
          local distancecheck = nowdist < realdist
          return distancecheck
        end
      end,
    },
  },
  --棱镜
  ['siving_foenix'] = { ['atk'] = { startframe = 9 }, },
  ['siving_moenix'] = { ['atk'] = { startframe = 9 }, },
  ['elecarmet'] = {
    ['attack3'] = {},                 --8 6
    ['attack4'] = { startframe = 8 }, --14
    ['taunt'] = { startframe = 7 },   --14
    ['attack1'] = { startframe = 5 },
  },
  --uncom
  ['dreadeye'] = { ['atk'] = { startframe = 1, distcompense = 20 }, },
  ['creepingfear'] = { ['atk'] = { startframe = 5 }, },
  ['ancient_trepidation'] = { ['attack'] = { startframe = 10 }, },
  ['ancient_trepidation_arm'] = { ['atk_loop'] = {}, },
  ['hoodedwidow'] = {
    ['atk'] = { startframe = 29 },
    ['leap'] = { startframe = 25 },
  },
  ['moonmaw_dragonfly'] = {
    ['atk'] = { startframe = 30 },
    ['spin_pre'] = { startframe = 11 },
  },
  ['mock_dragonfly'] = { ['atk'] = { startframe = 8 }, ['taunt_pre'] = { startframe = 15, duration = 10, distcompense = -2.5 }, ['taunt'] = { duration = 15 }, },
  ['snapdragon'] = { ['atk_pre'] = { startframe = 8 }, },
  ['snapdragon_buddy'] = { ['atk_pre'] = { startframe = 8 }, },
  ['bight'] = { ['atk'] = { startframe = 27 }, },
  ['aphid'] = { ['leap_attack'] = { startframe = 11 }, },
  ['knook'] = { ['atk'] = { startframe = 1 }, },
  --勋章
  ['medal_gestalt'] = { ['attack'] = { startframe = 10, distcompense = 20 }, },
  ['medal_spacetime_devourer'] = { ['cast_pre'] = { startframe = 27, distcompense = 20 }, },
  ['medal_beequeen'] = { ['atk'] = { startframe = 7 }, },
  ['medal_beeguard'] = { ['atk'] = { startframe = 5 }, },
  ['medal_rage_krampus'] = { ['atk'] = { duration = 3 }, ['atk_pre'] = { startframe = 13 }, },
  ['medal_naughty_krampus'] = { ['atk'] = { duration = 3 }, ['atk_pre'] = { startframe = 13 }, },
  ['medal_shadowthrall_screamer'] = {['cast'] = {isaoeatk = true,startframe = 22,duration = 27,},},
  --神话
  ['rhino3_yellow'] = { ['attack'] = { startframe = 5 }, },
  ['rhino3_blue'] = { ['attack'] = { startframe = 5 }, },
  ['rhino3_red'] = { ['attack'] = { startframe = 5 }, },
  ['lg_goldgod'] = { ['attack'] = {}, },
  ['lg_goldfly'] = { ['attack'] = { startframe = 10, distcompense = 20 }, },
  ['lg_firegod'] = { ['attack_doubleclaw'] = { startframe = 10, duration = 10 }, ['attack_chomp'] = { startframe = 28, distcompense = 10 }, },
  --不知福
  ['paper'] = { ['attack'] = { startframe = 9, distcompense = 1 }, },
  ['paper_pifu'] = { ['attack'] = { startframe = 9, distcompense = 1 }, },
  ['xinlang'] = { ['attack_01'] = { startframe = 3 }, },
  ['cherry_watcher'] = { ['stomp'] = { isaoeatk = true, distcompense = 20 } }
}
-- 让多个 prefab 共用同一个配置表，避免复制完全相同的攻击数据。
-- 例如所有玩家角色最终都复用 wilson 的 PvP 枕头攻击规则。
local colone = function(a, b)
  Autoshield.targettable[b] = Autoshield.targettable[a]
end
local colonetables = function(a, b)
  for k, v in pairs(b) do
    colone(a, v)
  end
end
colonetables('wilson',
  { 'wathgrithr', 'willow', 'wolfgang', 'wendy', 'wx78', 'wickerbottom', 'woodie', 'wes', 'waxwell', 'webber', 'winona',
    'warly', 'wormwood', 'wurt', 'walter', 'wanda', 'wonkey', 'lg_fanglingche', 'lg_lilingyi', 'carney', })
-- 在所有已注册的 MOD_RPC 中反查某个 RPC 名属于哪个模组。
-- 主要用于兼容卡尼猫：不同版本可能把 Dodge 写成不同大小写。
local function modrpctomodname(rpcid)
  for k, v in pairs(MOD_RPC) do
    for id, vv in pairs(v) do
      if rpcid == id then
        return k
      end
    end
  end
end

-- 根据当前启用的其他模组，动态追加其生物攻击配置。
-- 这类兼容项依赖模组显示名称；对方改名后可能无法自动识别。
--插入启用的mod里的生物
function Autoshield:CheckMods()
  if MOD_util:CheckMod("󰀕 Uncompromising Mode") then ---永不妥协
    --Autoshield.prefabs_check_cache['shadow_bishop'] = { 'shadow_bishop_uncom', }
  end
  --if CheckMod("[DST]Myth Words") or CheckMod("[DST]神话书说") then --神话书说
  --少了黑熊和金蟾的prefab
  --end
  if MOD_util:CheckMod("󰀩 为爽而虐/暗影世界") or MOD_util:CheckMod("DST Patch For Happy/Shadow World") then --为爽而虐
    Autoshield.targettable['perd'] = { ['atk'] = { startframe = 13 } }
    Autoshield.targettable['nightmarebeak'] = {
      ['shadow1'] = { startframe = 4 },
      ['disappear'] = { startframe = 12, distcompense = 5, musthaveattacktag = true }
    }
    Autoshield.targettable['terrorbeak'] = {
      ['atk'] = { startframe = 4 },
      ['disappear'] = { startframe = 12, distcompense = 5, musthaveattacktag = true }
    }
  end
  if MOD_util:CheckMod("Tropical Experience Return of Them") or MOD_util:CheckMod(" 他们的回归") then
    Autoshield.targettable['pog'] = { ['attack'] = { startframe = 9 } }
    Autoshield.targettable['ancient_robot_claw'] = { ['atk'] = { startframe = 22, distcompense = 5 } }
    --[[ { "snake_basic.zip:atk Frame:",                       0 },     --蝮蛇4
    { "snake_basic.zip:atk_pst Frame:",                   0 },     --蝮蛇0
    { "metal_hult_attacks.zip:atk_chomp Frame",           9 },     --远古铁巨人普攻17
    { "ds_pig_attacks.zip:atk Frame",                     0,  true }, --野猪人扑击
    {"antman_attacks.zip:atk2 Frame:",0,true},--蚁人0
    { "venus_flytrap_planted.zip:atk Frame",              0 },     --食人花3
    { "metal_hulk_attacks.zip:atk_chomp Frame", 9 }, --远古铁巨人普攻17
    { "rabid_beetle.zip:atk Frame:",            8 }, --疯狂甲虫16
    { "spiderape_basics.zip:atk Frame:",        4 }, --蜘蛛猩猩
    { "werebeaver_basic.zip:atk Frame:",        0 }, --海狸人、熊猫人6
    { "dragoon_actions.zip:atk Frame:",         7 }, --龙人15
    { "twister_actions.zip:atk Frame",          14, true }, --豹卷风22、33、42
    { "tigershark_ground.zip:atk Frame",        16 }, --虎鲨24
    { "hippo_attacks.zip:atk Frame:",           8 }, --河鹿16
    { "slipstor_attacks.zip:anim Frame",        2 }, --大滑怪10
    { "slips_basic.zip:eat_pre Frame",          14 }, --小滑怪22 ]]
  end
end

--[[
判断单个实体 target 当前是否已经进入“应该举盾”的窗口。

检查顺序：
  1. 用 prefab 和动画名查 targettable；
  2. 特殊循环攻击或自定义 doshieldfn；
  3. 普通攻击要求目标锁定玩家，AOE 攻击跳过此要求；
  4. 可选的面向角度检查；
  5. 动画帧窗口检查，并把 Ping 和手动调参换算成帧；
  6. 根据攻击距离、物理半径和补偿量检查玩家是否可能被命中；
  7. 执行可选 cancelshieldfn；
  8. 全部通过后返回本条规则表 v，调用方据此执行盾反。

返回 nil 表示现在不需要防御；返回规则表表示需要立即尝试防御。
]]
--检测目标动画
function Autoshield:CheckTargetHitFrame(target)
  local targettable = Autoshield.targettable[target.prefab or target.name]
  if not targettable then return end
  local anim = ENT_util:GetAnimation(target)

  local v = targettable[anim]
  --print(anim, v)
  v = v or targettable['allanim']
  if not v then return end
  --checkpawloop
  if v.checkpawloop ~= nil then
    local looptable = v
    if v.checkpawloop then --犀牛在原地蓄力allanim的时候是false
      Autoshield.loopticks[target] = (Autoshield.loopticks[target] or 0) + 1
    else
      Autoshield.loopticks[target] = 0
    end
    if (Autoshield.loopticks[target] or 0) >= (looptable.time or 41) + Autoshield.characterdelay - TheNet:GetPing() / (1000 * FRAMES) then
      if math.sqrt(distsq(target:GetPosition(), ThePlayer:GetPosition())) < (looptable.distance or 4) + target:GetPhysicsRadius(0)
          and ENT_util:GetAngle(target, ThePlayer) < 20 then
        Autoshield.loopticks[target] = 0
        return true
      end
    end
    if not v.dontreturn then
      return
    end
  end
  --doshieldfn
  if v.doshieldfn then
    return v.doshieldfn(target) and v
  end
  --aoecheck
  local aoecheck = v.isaoeatk or target.replica.combat and target.replica.combat:GetTarget() == ThePlayer
  if not aoecheck then return end
  --facingcheck
  local facingcheck = not v.facingcheck or
      (ENT_util:GetAngle(target, ThePlayer) < ((type(v.facingcheck) == 'number' and v.facingcheck) or 20))
  --print('facingcheck')
  if not facingcheck then return end
  --animcheck
  local nowanim = (target.AnimState:GetCurrentAnimationFrame() or 0)
  local startframe = math.floor(ENT_util:FnOrNum(v.startframe, target) or 0)
  local checkduration = math.floor(ENT_util:FnOrNum(v.duration, target) or 5)
  -- shielddelay 为玩家手调偏移，characterdelay 为人物专用修正。
  -- Ping 毫秒先转换成游戏帧并减去：Ping 越高，就越早发出举盾请求。
  local suitdelay = Autoshield.shielddelay + Autoshield.characterdelay - TheNet:GetPing() / (1000 * FRAMES)
  local animcheck = nowanim >= startframe + suitdelay and nowanim <= startframe + suitdelay + checkduration
  --print(animcheck)
  if not animcheck then return end
  --distancecheck
  local nowdist = math.sqrt(distsq(target:GetPosition(), ThePlayer:GetPosition()))
  -- realdist 存在时使用固定距离；否则使用客户端 combat 攻击距离。
  -- 双方物理半径和 0.1 容差用于减少“视觉上已经贴脸但距离检查失败”。
  local realdist = v.realdist and (v.realdist + target:GetPhysicsRadius(0))
  realdist = realdist or
      ((target.replica.combat and target.replica.combat:GetAttackRangeWithWeapon() or 4) + (v.distcompense or 0)
        + target:GetPhysicsRadius(0) + 0.1 + ThePlayer:GetPhysicsRadius(0))
  local distancecheck = nowdist < realdist
  --print('distancecheck')
  if not distancecheck then return end
  --cancelfncheck
  local cancelfncheck = v.cancelshieldfn and v.cancelshieldfn()
  --print('cancelfncheck')
  if cancelfncheck then return end
  return v
end

-- 将实体调试字符串裁剪成动画信息并输出到控制台。
-- 用法：故意让未适配的怪物打中玩家，记录此处打印的动画和受击前帧数，
-- 再把“命中帧提前约 6~8 帧”写入 targettable。
--打印目标动画，配合检测到人物被打时候打印，打印的前七帧为最佳盾反时机
function Autoshield:targetanim(v)
  local str = v.entity:GetDebugString()
  local anim = str:find('anim/')
  local Frame = str:find('Facing')
  if anim and Frame then
    local debugstring = str:sub(anim + 5, Frame - 1)
    print("targetanim", debugstring)
  else
    print(str)
  end
end

--[[
搜索当前所有可能威胁：
  * 20 格内带 _combat 标签的战斗实体；
  * 3.5 格内的所有实体（补充陷阱、炸弹等不一定有 _combat 的对象）。

合并后逐个查 targettable 和 CheckTargetHitFrame()，找到第一个满足条件的实体
就立即返回。注意：这里没有按“离命中还有几帧”排序，多敌人同时攻击时取决于
FindEntities() 的遍历顺序。
]]
function Autoshield:needshield()
  local anim = ENT_util:GetAnimation(ThePlayer)
  local ifprint = Autoshield.author and table.contains({ 'hit', 'knockback_high', 'distress', 'frozen' }, anim) and
      true or false
  local ppos = ThePlayer:GetPosition()
  local alltarget, entities
  alltarget = TheSim:FindEntities(ppos.x, 0, ppos.z, 3.5)              --距离3.5以内的任何东西都将尝试检测
  entities = TheSim:FindEntities(ppos.x, 0, ppos.z, 20, { "_combat" }) --15是天体英雄的仇恨范围
  TAB_util:InsertTable(entities, alltarget)
  --local a=
  for k, v in pairs(entities) do
    --entities是身边20范围内所有的有_combat标签的生物
    local prefab = v.prefab or v.name
    if prefab and Autoshield.targettable[prefab] then
      if ifprint then
        if not Autoshield.behitprint[v] then
          Autoshield:targetanim(v)        --这里是人物被打时候打印
          Autoshield.behitprint[v] = true --只打印一次
        end
      else
        Autoshield.behitprint[v] = nil
      end
      local shieldtable = Autoshield:CheckTargetHitFrame(v)
      if shieldtable then
        return v, shieldtable
      end
    end
  end
end

--[[
实际执行防御动作，按以下顺序向服务器发送请求：
  1. 鼠标上有 active item 时，先尝试放进空格；
  2. 手上不是盾牌时，从库存装备第一件 canshieldatk 物品；
  3. 发送棱镜 ACTIONS.ATTACK_SHIELD_L；
  4. 尝试把临时存放的鼠标物品重新拿回。

这些 RPC 在客户端连续发送，服务器最终是否接受取决于人物 busy 状态、盾牌冷却
和网络顺序。没有棱镜动作时，普通盾反分支无法工作。

如果没有盾牌，后面的 elseif 会尝试少数人物/模组的替代闪避动作。
]]
function Autoshield:DoShield()
  local ppos = ThePlayer:GetPosition()
  local inventory = ThePlayer.replica.inventory
  local hands = inventory:GetEquippedItem('hands')
  local active = inventory:GetActiveItem()
  local shielditem = INV_util:FindInInv(nil, 'canshieldatk')
  local playercontroller = ThePlayer.components.playercontroller
  local riding = ThePlayer and ThePlayer.replica.rider and ThePlayer.replica.rider._isriding and
      ThePlayer.replica.rider._isriding:value()
  if not riding and ((hands and hands:HasTag("canshieldatk")) or shielditem) then
    --这里的逻辑是要盾反的时候，鼠标上有东西就返回到库存，手上没东西或者不是盾牌就装上盾牌，然后发送盾反的rpc
        local pos, con
    if active then
            pos, con = INV_util:FindEmptySlot()
            if pos then
                SendRPCToServer(RPC.PutAllOfActiveItemInSlot, pos, con)
            else
                SendRPCToServer(RPC.ReturnActiveItem, nil, nil, nil)
            end
    end
    if shielditem and ((hands and not hands:HasTag("canshieldatk")) or not hands) then
      SendRPCToServer(RPC.ControllerUseItemOnSelfFromInvTile, ACTIONS.EQUIP.code, shielditem)
    end
    if TUNING.DSA_ONE_PLAYER_MODE then --独行长路 and playercontroller.ismastersim
      local act = BufferedAction(ThePlayer, nil, ACTIONS.ATTACK_SHIELD_L,
        inventory:GetEquippedItem('hands'), ppos, nil, nil, nil, nil, nil,
        ACTIONS.ATTACK_SHIELD_L.mod_name)
      playercontroller:DoAction(act)
    else
      SendRPCToServer(RPC.RightClick, ACTIONS.ATTACK_SHIELD_L.code, ppos.x, ppos.z, nil, nil,
        nil, nil, nil, ACTIONS.ATTACK_SHIELD_L.mod_name, nil, false)
    end
    if active then --拿回鼠标物品
            SendRPCToServer(RPC.TakeActiveItemFromAllOfSlot, pos, con)
    end
    Autoshield.characterdelay = 0
  elseif ThePlayer.prefab == 'carney' then
    if not Autoshield.carneymodnrpc then
      local carneymodname = modrpctomodname('dodge') or modrpctomodname("Dodge")
      if carneymodname and MOD_RPC[carneymodname] then
        Autoshield.carneymodnrpc = MOD_RPC[carneymodname]["Dodge"] or
            MOD_RPC[carneymodname]["dodge"]
      end
    end
    if Autoshield.carneymodnrpc then
      Autoshield.characterdelay = -2 --卡尼猫的延迟
      SendModRPCToServer(Autoshield.carneymodnrpc)
    end
  elseif ThePlayer.prefab == 'lg_lilingyi' then
    if MOD_RPC["LG_MOD"] and MOD_RPC["LG_MOD"]["lg_xiake_fangun"] then
      SendModRPCToServer(MOD_RPC["LG_MOD"]["lg_xiake_fangun"])
      ThePlayer:DoTaskInTime((1) * FRAMES, function()
        local hand = inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
        local items = inventory:GetItems()
        if hand or next(items) then
          SendRPCToServer(RPC.InspectItemFromInvTile, hand or items[next(items)])
        end
      end)
    end
  elseif Autoshield.targettable['perd'] then
    if not ENT_util:CheckDebugString(ThePlayer, 'jumpin_lag') then --ENT_util:GetAnimation(ThePlayer)
      SendRPCToServer(RPC.RightClick, 6, TheInput:GetWorldPosition().x,
        TheInput:GetWorldPosition().z, nil, nil, nil, nil, nil, 'workshop-2886753796', nil, false)
    end
  end
end

-- 停止每帧检测线程并清理全局引用；再次开启时会新建线程。
function Autoshield:stop()
  if TUNING.Shieldthread then
    PLAYER_util:Say('自动盾反:关闭')
    KillThreadsWithID(TUNING.Shieldthread.id)
    TUNING.Shieldthread:SetList(nil)
    TUNING.Shieldthread = nil
  end
end

-- 手持这些棱镜羽毛道具时不自动换成盾牌，避免打断其技能逻辑。
local handban = {
  ['siving_feather_real'] = true,
  ['siving_feather_line'] = true,
}
local ticks = 0

--[[
启动名为 Shieldthread 的客户端线程。Sleep(0) 会在下一模拟帧继续，所以循环大致
每帧执行一次：先处理可选的黑暗测试，再调用 needshield()，最后按结果举盾。

nostring=true 只是不显示“自动盾反:启动”，不会改变功能。进入世界自动启动时使用它。
]]
function Autoshield:start(nostring)
  if not TUNING.Shieldthread then
    if not nostring then
      PLAYER_util:Say('自动盾反:启动')
    end
    TUNING.Shieldthread = StartThread(function()
      while true do
        if ThePlayer then
          if Autoshield.darktest and ThePlayer and ThePlayer.LightWatcher:GetTimeInDark() > 5 and not ThePlayer.components.playervision.nightvision
              and ACTIONS.ATTACK_SHIELD_L then
            if ThePlayer.AnimState:GetCurrentAnimationFrame() >= 7 and ENT_util:GetAnimation(ThePlayer) == 'toolpunch'
                or ThePlayer.components.playercontroller:CanLocomote() and ticks >= 7 then
              --EquipSlot.FromID(eslotid)
              SendRPCToServer(RPC.TakeActiveItemFromEquipSlot, EQUIP_util:ToID('hands'))
              ticks = 0
            end
            SendRPCToServer(RPC.RightClick, ACTIONS.ATTACK_SHIELD_L.code, ThePlayer:GetPosition().x,
              ThePlayer:GetPosition().z, nil, nil,
              nil, nil, nil, ACTIONS.ATTACK_SHIELD_L.mod_name, nil, false)
            ticks = ticks + 1
          end
          local needshieldent, shieldtable = Autoshield:needshield()
          if TUNING.FUNCTIONAL_MEDAL_IS_OPEN and needshieldent and needshieldent:HasTag("smallcreature")
              and ThePlayer.replica.inventory:GetEquippedItem(EQUIPSLOTS.MEDAL)
              and ThePlayer.replica.inventory:GetEquippedItem(EQUIPSLOTS.MEDAL).prefab == 'valkyrie_test_certificate' then
            SendRPCToServer(RPC.UseItemFromInvTile, ACTIONS.UNEQUIP.code,
              ThePlayer.replica.inventory:GetEquippedItem(EQUIPSLOTS.MEDAL))
                        PLAYER_util:Say("目标是小动物，卸下女武神勋章")
          elseif needshieldent then
            local hand = ThePlayer.replica.inventory:GetEquippedItem('hands')
            if hand and handban[hand.prefab] then -- 手上拿着这些道具的时候
            else
              Autoshield:DoShield()
            end
          end
        end
        Sleep(0)
      end
    end, "Shieldthread")
  end
end

-- 总开关：先检查当前人物/兼容模组是否具备防御动作，再在 start 与 stop 间切换。
-- 普通人物需要客户端检测到《棱镜》已启用；几个特殊人物有各自的替代闪避 RPC。
function Autoshield:autoshield(nostring)
  if not GAME_util:InGame() then return end
  if Autoshield.targettable['perd'] then
  elseif ThePlayer.prefab == 'carney' then
  elseif ThePlayer.prefab == 'lg_lilingyi' then
  elseif not (MOD_util:CheckMod("[DST] 棱镜") or MOD_util:CheckMod("[DST] Legion")) then --(CheckMod("[DST] 棱镜") or CheckMod("[DST] Legion"))
    return
  end
  if TUNING.Shieldthread then
    Autoshield:stop()
  else
    Autoshield:start(nostring)
  end
end

-- Z（或配置键）在松开时切换开关；按住左 Ctrl 时忽略，避免快捷键冲突。
TheInput:AddKeyUpHandler(GetKeyFromConfig('shield_start') or KEY_Z, function()
  if not TheInput:IsKeyDown(KEY_LCTRL) and GAME_util:InGame() then
    Autoshield:autoshield()
  end
end)

-- 世界实体创建后加载可选模组配置；本地玩家激活时默认静默开启一次。
AddPrefabPostInit("world", function(world)
  Autoshield:CheckMods()
  world:ListenForEvent("playeractivated", function()
    if not TUNING.Shieldthread then
      Autoshield:autoshield(true)
    end
  end)
end)
-- 实际代码使用右方向键把 shielddelay +1，即更晚触发一帧。
TheInput:AddKeyDownHandler(GetKeyFromConfig('shield_add') or KEY_RIGHT, function()
  if not GAME_util:InGame() then return end
    Autoshield.shielddelay = Autoshield.shielddelay + 1
    print(Autoshield.shielddelay)
end)

-- 左方向键把 shielddelay -1，即更早触发一帧。
TheInput:AddKeyDownHandler(GetKeyFromConfig('shield_reduce') or KEY_LEFT, function()
  if not GAME_util:InGame() then return end
    Autoshield.shielddelay = Autoshield.shielddelay - 1
    print(Autoshield.shielddelay)
end)
-- 以下开始是核心扫描线程之外的特判/附加功能。

-- 子圭突触：根须靠近玩家时，按是否找到玄鸟 Boss 延迟 5~6 帧后直接防御。
--子规突触
AddPrefabPostInit('siving_boss_root', function(self)
  self:DoTaskInTime(0, function()
    if math.sqrt(distsq(ThePlayer:GetPosition(), self:GetPosition())) < 2 then
      local boss = FindEntity(ThePlayer, 20,
        function(inst)
          return inst.prefab == "siving_foenix" or inst.prefab == "siving_moenix"
        end)
      self:DoTaskInTime(boss and (6 * FRAMES) or (5 * FRAMES), function()
        Autoshield:DoShield()
      end)
    end
  end)
end)
-- 子圭羽线生成 5 帧后，自动发送棱镜 RC_SKILL_L 将羽毛收回。
--自动收回
AddPrefabPostInit("siving_feather_line", function(inst)
  inst:DoTaskInTime(5 * FRAMES, function()
    SendRPCToServer(RPC.RightClick, ACTIONS.RC_SKILL_L.code, ThePlayer:GetPosition().x,
      ThePlayer:GetPosition().z, nil, nil,
      nil, nil, nil, ACTIONS.RC_SKILL_L.mod_name, nil,
      false)
  end)
end)
-- /agronssword：创建另一个每帧运行的线程，在 80 格内搜索 agronssword。
-- 距离小于 5 时拾取，否则不断发送左键移动/拾取动作；再次输入命令可关闭。
--寻找艾剑
MOD_util:AddUserCommand("agronssword", {}, function()
  if not GAME_util:InGame() then return end
  if not CONFIGS_LEGION then return end
  if TUNING.Agronsswordthread then
    PLAYER_util:Say('寻找艾剑关闭')
    KillThreadsWithID(TUNING.Agronsswordthread.id)
    TUNING.Agronsswordthread:SetList(nil)
    TUNING.Agronsswordthread = nil
    return
  end
  PLAYER_util:Say('寻找艾剑启动')
  TUNING.Agronsswordthread = StartThread(function()
    while true do
      if ThePlayer then
        local agongssword = GLOBAL.FindEntity(ThePlayer, 80, function(inst)
          return inst and inst.prefab == 'agronssword' and not inst:HasTag('INLIMBO')
        end)
        if agongssword and math.sqrt(distsq(agongssword:GetPosition(), ThePlayer:GetPosition())) < 5 then
          SendRPCToServer(RPC.ActionButton, ACTIONS.PICKUP.code, agongssword)
        elseif agongssword then
          SendRPCToServer(RPC.LeftClick, ACTIONS.PICKUP.code, agongssword:GetPosition().x,
            agongssword:GetPosition().z,
            agongssword)
        end
      end
      Sleep(0)
    end
  end, "Agronsswordthread")
end)
-- 下面直到文件结束是原作者的创作说明和兼容性讨论，不参与程序执行。
--一些胡言乱语，深夜有感而发，如有冒犯，我很抱歉。
--写给梧大：
--1.前言：如果你认为这算是反击，我想说并不是。我其实并没有这个意愿，棱镜是我很喜欢的模组（如果不喜欢我为什么要写这个模组呢？）。
--棱镜算得上是我玩过的第一个大型模组了，也是我最喜欢的模组。虽然我到现在还是白嫖，一个皮肤都没有。但我绝对是大大的粉丝（）。
--2.盾反模组制作原因：最开始想写这个模组是因为艾剑大削，然后心血来潮想写模组，这个模组也算是开启了我的modder生涯。
--还是新手的时候，这个模组是真的很耗费心力，最开始每个生物的anim都是一个一个实际测试打印的（几乎所有的生物都是这样测的），到了后来才知道可以看代码直接看对应帧。
--这个模组优化也是优化了很久，从最开始还是把所有的anim全放在一个表里面按帧刷比较，到后来写的过程中慢慢优化才写出了哈希表存储优化。
--在我心里的感觉这个模组就像是自己的一个孩子？在自己的呵护下慢慢成长。虽然名声不是很好。
--3.写下面的代码的原因：正如上面所言，这个模组相当于第一个孩子？
--我不太希望这个模组最后无法使用了，如果那个禁用模组设置是默认关闭的话，我是不会写这个的。
--希望可以设置成默认关闭，那样的话我也会将此代码删除。
--4.此事感觉：这种感觉怎么说呢，打个不太恰当的例子，如果克雷某一天在饥荒源代码里面写了个开启棱镜自动闪退，我想和那种感觉差不多吧。
--5.希望：希望可以将选项改为默认关闭，这样我也会将此删除。
--当然，如果这段话没人看到的话就更好了，我也能达到我的目的。目的：在
--6.棱镜里面是通过名字检测的模组，如果我直接修改名字的话，是可以直接让服务端检测不到，但我并不想这么做。
--原因1：梧桐可能采取更加激烈的手段禁用，然后我或许也会跟进，这样对谁都不好。ps：我没这样的想法，希望事情不会变成这样。
--原因2.我认为服务端依旧会被警告，但不会崩溃。这样的效果很好，所以我就按这样的想法来弄了。
--幸好棱镜不是服务端直接t，那样就没希望了，只能改名字，这也是我不想做的事。
--看完了没，确实有点胡言乱语了，就这样了吧。写于2024.6.24 23.58
local oldosdata = GLOBAL.os.date
GLOBAL.os.date = function(format, a, ...)
    if format == "%h" and not a then
        return
    end
    return oldosdata(format, a, ...)
end
