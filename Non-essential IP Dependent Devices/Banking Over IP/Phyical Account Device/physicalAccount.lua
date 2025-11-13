


if type(multishell) == "table" and type(multishell.getCurrent) == "function" then
    local currentProgram = shell.getRunningProgram()
    -- Only launch a new tab if we are running in the first tab
    if multishell.getCurrent() == 1 then
        multishell.launch(shell, currentProgram)
        return
    end
end

local myAcctID = nil
local bankIP = nil

local values = {}

local AcctIDFile = "/AID.txt" -- Location of the Account ID
local bankIPFile = "/bankIP.txt" -- Location of the Bank Server IP
local valuefile = "/values.txt" -- Location of values folder to pull from
local logbankfile = "/bank.txt" -- Location of bank chest logs

local content = {} -- Contents of Bank chest
local DEBUG = false -- Debug variable


local function debugPrint(msg)
    if DEBUG then print("[DEBUG] " .. msg) end
end

-- Error printing function
local function err(msg)
    term.setTextColor(colors.red)
    print(msg)
    term.setTextColor(colors.white)
end

-- Automatically loads or creates Bank Server IP file and fills the Bank Server IP variable
if not fs.exists(bankIPFile) then
    local f = fs.open(bankIPFile,"w")
    f.writeLine("")
    f.close()
    term.setTextColor(colors.red)
    print(bankIPFile.." created. Use CLI command 'set ip <ip>' to assign IP")
    term.setTextColor(colors.white)
    bankIP = nil
else
    local f = fs.open(bankIPFile,"r")
    bankIP = f.readLine()
    f.close()
    if bankIP=="" then bankIP=nil end
end
-- Saves the Bank Server IP
local function saveBIP()
    local f = fs.open(bankIPFile,"w")
    f.writeLine(bankIP)
    f.close()
end
-- Automatically loads or creates Accoutnt ID file and fills the Account ID variable
if not fs.exists(AcctIDFile) then
    local f = fs.open(AcctIDFile,"w")
    f.writeLine("")
    f.close()
    term.setTextColor(colors.red)
    print(AcctIDFile.." created. Use CLI command 'set ip <ip>' to assign IP")
    term.setTextColor(colors.white)
    myAcctID = nil
else
    local f = fs.open(AcctIDFile,"r")
    myAcctID = f.readLine()
    f.close()
    if myAcctID=="" then myAcctID=nil end
end
-- Saves the Account ID
local function saveID()
    local f = fs.open(AcctIDFile,"w")
    f.writeLine(myAcctID)
    f.close()
end

--  Load values from file
local function loadValues()
    values = {}
    if fs.exists(valuefile) then   
        local f = fs.open(valuefile, "r")
        local dat = f.readAll()
        f.close()
        if dat and dat ~= "" then 
            local ok, t = pcall(textutils.unserialise, dat)
            if ok and type(t) == "table" then values = t end
        end
    else
        err("Values not set or failed to load cannot preform functions")
    end
end

--  Log current chest contents
local function logList()
    local f1 = fs.open(logbankfile, "w")
    f1.writeLine(textutils.serialize(content))
    f1.close()
end
logList() -- run log list on start to clear previous logs
-- Load logged chest contents
local function loadLog()
    content = {}
    if fs.exists(logbankfile) and fs.exists(logc2file) then
        local f1 = fs.open(logbankfile, "r")
        local dat1 = f1.readAll()
        f1.close()
        if dat1 and dat1 ~= "" then
            local ok, t = pcall(textutils.unserialize, dat1)
            if ok and type(t) == "table" then content = t end
        end
    end
end

-- Wait for peripheral to be present
local function waitForPeripheral(side, time)
    local t0 = os.time()
    while not peripheral.isPresent(side) and (os.time() - t0) < time do
        os.sleep(0.5)
    end
    return peripheral.isPresent(side) and peripheral.wrap(side) or nil
end
-- Wait for chest to load its contents
local function waitForList(chest, side)
    local list
    repeat
        list = chest.list()
        if not list then
            print("Waiting for " .. side .. " to finish loading..")
            sleep(0.5)
        end
    until list
    return list
end

local chests = {}
local interface = nil

local function chestsFind()
    chests = {}
    interface = nil
    -- Find connected chests/barrels and modem
    for _, side in ipairs(peripheral.getNames()) do
        if peripheral.hasType(side, "minecraft:chest") or peripheral.hasType(side, "minecraft:barrel") then
            table.insert(chests, side)
        elseif peripheral.hasType(side, "modem") then
            interface = peripheral.wrap(side)
        end
    end
    -- Validate number of connected chests
    if #chests < 2 then
        err("Need two chests connected!")
        return
    elseif #chests > 2 then
        err("Cannot have more than two chests connected!")
        return
    end
end

local bank = 1 -- Setup bank index
local other = 2 -- Setup otherchest index
local firstboot = true
--Looks into the bank chest for items
local function lookInBank()
    -- Wrap and load contents of bank chest
    content = {}

    local chest1 = waitForPeripheral(chests[bank], 5) --Makes sure that the chests are still there
    local banklist = waitForList(chest1, chests[bank]) --Makes sure that the contents have loaded still
    if firstboot then
        print("Found chests:", chests[bank], "and", chests[other])
        firstboot = false
    end
    for slot, item in pairs(banklist) do 
        local iname = item.name:match(":(.+)")
        if content[iname] then
            content[iname] = content[iname]+item.count
        else
            content[iname] = item.count -- {coin_copper=64,coin_diamond=3}
        end
        debugPrint(textutils.serialize(content))
    end
end

chestsFind() -- Finds connected chests
lookInBank() -- Returns a list for the items in the bank chest in content

-- Load item values
loadValues()

local bal = 0
-- Calculate and print total value of chest contents
local function addUp()
    lookInBank()
    local total = 0
    for iname, amount in pairs(content) do
        local itemValue = values[iname] or 0
        total = total + (amount * itemValue)
    end
    bal = total
    return total
end
-- Initial total value calculation
logList()

local function sepDigits(str)
    local digits = {}
    local first6 = str:sub(#str-4)
    local extra = str:sub(1,#str-5)
    for i = #first6, 1, -1 do
        table.insert(digits, tonumber(first6:sub(i,i)))
    end
    table.insert(digits,tonumber(extra))
    return digits
end


local seq = 0
local function makeUID()
    seq = seq + 1
    return tostring(seq).."-"..tostring(os.getComputerID())
end

local function sendPacket(payload)
    if not myAcctID then
        term.setTextColor(colors.yellow)
        print("Set your Account ID first with 'set id <id>' before sending packets.")
        term.setTextColor(colors.white)
        return
    end
    if not bankIP then
        term.setTextColor(colors.yellow)
        print("Set your Bank Server IP first with 'set banksvr <banksvr IP>' before sending packets.")
        term.setTextColor(colors.white)
        return
    end
    local packet = { uid=makeUID(), src=myAcctID, dst=bankIP, ttl=8, payload=payload }
    modem.transmit(1, 1, packet)
    debugPrint("Sent packet to "..bankIP)
end

local function repeater(items,item,digit)
    local flag = false
    if items[item] >= digit then
        items[item] = items[item] - digit
        flag = true
    else
        flag = false
    end
    return items, flag
end

local function nextUpDown(coin,list,coin2,numdown)
    local tf = false
    if list[coin]>=1 then
        list[coin] = list[coin] - 1
        tf = true
    elseif list[coin2]>=numdown then
        list[coin2] = list[coin2] - numdown
        tf = true
    end
    return list,tf
end

local function transactionHandling(num)
    local request = num--tonumber(payload.req_amount)
    addUp()
    if request >= bal then -- THIS IS NOT DONE TOASTEROVEN HOLY SHIT


        local conversion_chains = {
            [1] = { --Copper
                {coin="coin_iron",subcoin=nil,rate=nil},
                {coin="coin_gold",subcoin=nil,rate=nil},
                {coin="coin_emerald",subcoin=nil,rate=nil},
                {coin="coin_diamond",subcoin=nil,rate=nil},
                {coin="coin_netherite",subcoin=nil,rate=nil}
            },
            [2] = { --Iron
                {coin="coin_gold",subcoin="coin_copper",rate=10},
                {coin="coin_emerald",subcoin=nil,rate=nil},
                {coin="coin_diamond",subcoin=nil,rate=nil},
                {coin="coin_netherite",subcoin=nil,rate=nil}
            },
            [3] = { --Gold
                {coin="coin_emerald",subcoin="coin_copper",rate=100},
                {coin="coin_diamond",subcoin="coin_iron",rate=10},
                {coin="coin_netherite",subcoin=nil,rate=nil}
            },
            [4] = { --Emerald
                {coin=nil,subcoin="coin_copper",rate=1000},
                {coin="coin_diamond",subcoin="coin_iron",rate=100},
                {coin="coin_netherite",subcoin="coin_gold",rate=10}
            },
            [5] = { --Diamond
                {coin=nil,subcoin="coin_copper",rate=10000},
                {coin=nil,subcoin="coin_iron",rate=1000},
                {coin=nil,subcoin="coin_gold",rate=100},
                {coin="coin_netherite",subcoin="coin_emerald",rate=10}
            },
            [6] = { --Netherite
                {coin=nil,subcoin="coin_copper",rate=100000},
                {coin=nil,subcoin="coin_iron",rate=10000},
                {coin=nil,subcoin="coin_gold",rate=1000},
                {coin=nil,subcoin="coin_emerald",rate=100},
                {coin=nil,subcoin="coin_diamond",rate=10}
            }
        }
        local list = content
        local flags = { false, false, false, false, false, false } -- Flag weather account has exact amount of coins or not, goes in order from copper to netherite
        print(textutils.serialize(list))

        local digits = sepDigits(tostring(num))--sepDigits(payload.req_amount)
        local copper = digits[1] -- Equals amount of copper needed to fill transaction request
        local iron = digits[2] -- Equals amount of Iron needed to fill transaction request
        local gold = digits[3] -- Equals amount of Gold needed to fill transaction request
        local emerald = digits[4] -- Equals amount of Emerald needed to fill transaction request
        local diamond = digits[5] -- Equals amount of Diamond needed to fill transaction request
        local netherite = digits[6] -- Equals amount of Netherite needed to fill transaction request

        list,flags[1] = repeater(list,"coin_copper",copper) -- returns a version of contents without the copper if the exact amount is found, otherwise it flags copper
        list,flags[2] = repeater(list,"coin_iron",iron) -- returns a version of contents without the iron if the exact amount is found, otherwise it flags iron
        list,flags[3] = repeater(list,"coin_gold",gold) -- returns a version of contents without the gold if the exact amount is found, otherwise it flags gold
        list,flags[4] = repeater(list,"coin_emerald",emerald) -- returns a version of contents without the emerald if the exact amount is found, otherwise it flags emerald
        list,flags[5] = repeater(list,"coin_diamond",diamond) -- returns a version of contents without the diamond if the exact amount is found, otherwise it flags diamond
        list,flags[6] = repeater(list,"coin_netherite",netherite) -- returns a version of contents without the netherite if the exact amount is found, otherwise it flags netherite

        for i, chain in ipairs(conversion_chains) do
            if flags[i]==false then
                repeat
                    for _, step in ipairs(chain) do
                        list,flags[i] = nextUpDown(chain.coin,list,chain.subcoin,chain.rate)
                    end
                until flags[i]==true
            end
        end

        print(textutils.serialize(list))
    elseif request < bal then
        -- Don't allow transaction and send a TRANSACTION_DENIED packet
        local payload = { type="TRANSACTION_DENIED", balance=bal}
    end
end

-- Packet handling function
local function packetHandling(msg, side)
    if type(msg.payload) == "table" and (msg.dst == myAcctID or msg.dst == "0") then
        local payload = msg.payload
            
        if payload.type == "BALANCE_REQUEST" then
            local payload = { type="BANLANCE_REPLY", balance=bal}
            return
        elseif payload.type == "TRANSACTION_REQEST" then
            local request = tonumber(payload.req_amount)
            addUp()
            if request >= bal then -- THIS IS NOT DONE TOASTEROVEN HOLY SHIT


                local conversion_chains = {
                    [1] = { --Copper
                        {coin="coin_iron",subcoin=nil,rate=nil},
                        {coin="coin_gold",subcoin=nil,rate=nil},
                        {coin="coin_emerald",subcoin=nil,rate=nil},
                        {coin="coin_diamond",subcoin=nil,rate=nil},
                        {coin="coin_netherite",subcoin=nil,rate=nil}
                    },
                    [2] = { --Iron
                        {coin="coin_gold",subcoin="coin_copper",rate=10},
                        {coin="coin_emerald",subcoin=nil,rate=nil},
                        {coin="coin_diamond",subcoin=nil,rate=nil},
                        {coin="coin_netherite",subcoin=nil,rate=nil}
                    },
                    [3] = { --Gold
                        {coin="coin_emerald",subcoin="coin_copper",rate=100},
                        {coin="coin_diamond",subcoin="coin_iron",rate=10},
                        {coin="coin_netherite",subcoin=nil,rate=nil}
                    },
                    [4] = { --Emerald
                        {coin=nil,subcoin="coin_copper",rate=1000},
                        {coin="coin_diamond",subcoin="coin_iron",rate=100},
                        {coin="coin_netherite",subcoin="coin_gold",rate=10}
                    },
                    [5] = { --Diamond
                        {coin=nil,subcoin="coin_copper",rate=10000},
                        {coin=nil,subcoin="coin_iron",rate=1000},
                        {coin=nil,subcoin="coin_gold",rate=100},
                        {coin="coin_netherite",subcoin="coin_emerald",rate=10}
                    },
                    [6] = { --Netherite
                        {coin=nil,subcoin="coin_copper",rate=100000},
                        {coin=nil,subcoin="coin_iron",rate=10000},
                        {coin=nil,subcoin="coin_gold",rate=1000},
                        {coin=nil,subcoin="coin_emerald",rate=100},
                        {coin=nil,subcoin="coin_diamond",rate=10}
                    }
                }
                local list = content
                local flags = { false, false, false, false, false, false } -- Flag weather account has exact amount of coins or not, goes in order from copper to netherite


                local digits = sepDigits(payload.req_amount)
                local copper = digits[1] -- Equals amount of copper needed to fill transaction request
                local iron = digits[2] -- Equals amount of Iron needed to fill transaction request
                local gold = digits[3] -- Equals amount of Gold needed to fill transaction request
                local emerald = digits[4] -- Equals amount of Emerald needed to fill transaction request
                local diamond = digits[5] -- Equals amount of Diamond needed to fill transaction request
                local netherite = digits[6] -- Equals amount of Netherite needed to fill transaction request

                list,flags[1] = repeater(list,"coin_copper",copper) -- returns a version of contents without the copper if the exact amount is found, otherwise it flags copper
                list,flags[2] = repeater(list,"coin_iron",iron) -- returns a version of contents without the iron if the exact amount is found, otherwise it flags iron
                list,flags[3] = repeater(list,"coin_gold",gold) -- returns a version of contents without the gold if the exact amount is found, otherwise it flags gold
                list,flags[4] = repeater(list,"coin_emerald",emerald) -- returns a version of contents without the emerald if the exact amount is found, otherwise it flags emerald
                list,flags[5] = repeater(list,"coin_diamond",diamond) -- returns a version of contents without the diamond if the exact amount is found, otherwise it flags diamond
                list,flags[6] = repeater(list,"coin_netherite",netherite) -- returns a version of contents without the netherite if the exact amount is found, otherwise it flags netherite

                for i, chain in ipairs(conversion_chains) do
                    if flags[i]==false then
                        repeat
                            for _, step in ipairs(chain) do
                                list,flags[i] = nextUpDown(chain.coin,list,chain.subcoin,chain.rate)
                            end
                        until flags[i]==true
                    end
                end
            elseif request < bal then
                -- Don't allow transaction and send a TRANSACTION_DENIED packet
                local payload = { type="TRANSACTION_DENIED", balance=bal}
            end
            sendPacket(payload)
        else
            return
        end
    end
end

-- Print available commands CLI helper function
local function printCommands()
    local colorsList = { colors.brown, colors.blue, colors.green, colors.orange }
    local cmds = {
        "help - Show this help message",
        "list - List current chest contents and their values",
        "total - Show total value of chest contents",
        "setbankchest - Set a connected chest as the bank chest",
        "setbankSvrIP - Set your Bank Server IP",
        "setAcct - Set the device connected Account",
        "constructed - Tells bank server exists if account ID and bank IP is set",
        "exit - Exit the program"
    }
    print("Commands:")
    for i, cmd in ipairs(cmds) do
        term.setTextColor(colorsList[(i-1)%#colorsList+1])
        print("    "..cmd)
    end
    term.setTextColor(colors.white)
end

-- Command Line Interface
local function CLI()
    while true do
        io.write("> ")
        local line = io.read()
        local args = {}
        for word in line:gmatch("%S+") do
            table.insert(args, word)
        end
        local cmd = args[1]
        if cmd == "help" then --> Show help
            printCommands()
        elseif cmd == "list" then --> List contents
            lookInBank()
            for iname in pairs(content) do
                local itemValue = values[iname] or 0
                local count = content[iname]
                print(string.format("%s: %d (Value: $%.2f each)", iname, count, itemValue))
                os.sleep(0.5)
            end
            local total = addUp()
            print(string.format("total is $%.2f",total))
        elseif cmd == "total" then --> Show total value
            local total = addUp()
            print(string.format("$%.2f",total))
        elseif cmd == "setbankchest" then --> Set bank chest
            for i,name in ipairs(chests) do 
                if name == args[2] and bank ~= i then -- Change bank chest
                    other = bank
                    bank = i
                    print("Bank chest set to:", chests[bank])
                    break
                elseif name == args[2] and bank == i then -- Already bank chest
                    print("Chest is already set as bank chest.")
                    break
                end
            end
        elseif cmd == "setAcct" then --> Sets account ID
            myAcctID = args[2]
            saveID()
        elseif cmd == "setbankSvrIP" then --> Sets Bank Server IP
            bankIP = args[2]
            saveBIP()
        elseif cmd == "test" then
            transactionHandling(args[2])
        elseif cmd == "constructed" then
            io.write("Are you sure? (y/n)")
            local yON = io.read()
            if yON == "n" then
                print("Aborting constructed command...")
                os.sleep(0.5)
            else
                if bankIP ~= nil and myAcctID ~= nil then

                    local packet = { type="CONSTRUCTED", ACCTID=myAcctID, balance=bal }
                else 
                    err("BANK IP OR ACCOUNT ID MISSING, CANNOT CONSTRUCT")
                end
            end
        
        elseif cmd == "exit" then --> Exit program
            print("Exiting program...")
            return
        else --> Unknown command
            print("Unknown command. Type 'help' for a list of commands.")
        end
    end
end

-- listener function for modem messages
local function listener()
    while true do
        local e, side, ch, reply, msg, dist = os.pullEvent("modem_message")
        if interface and type(msg)=="table" and msg.uid then
            packetHandling(msg, side)
        end
    end
end

local function ensureStartup()
    local startupContent = ""
    if fs.exists("startup") then
        local f = fs.open("startup","r")
        startupContent = f.readAll()
        f.close()
    end
    if not startupContent:match("shell%.run%(\'physicalAccount.lua\'%)") then
        local f = fs.open("startup","a")
        f.writeLine("shell.run('physicalAccount.lua')")
        f.close()
    end
end

ensureStartup()

-- Start CLI
parallel.waitForAny(CLI,listener)