--This is a template for if you want to make your own server for my network
-- Features include multishell launch
-- Debug printing with a command to turn it on and off
-- Automatic locating of connected modems
-- Multi-channel IP system
-- Reply to hello packets and switch hello packets
-- Receive loop to process recieved packets
-- Startup on boot

-- ==========================
-- SELF-LAUNCH IN MULTISHELL
-- ==========================
if type(multishell) == "table" and type(multishell.getCurrent) == "function" then
    local currentProgram = shell.getRunningProgram()
    -- Only launch a new tab if we are running in the first tab
    if multishell.getCurrent() == 1 then
        multishell.launch(shell, currentProgram)
        return
    end
end

-- ==========================
-- DEBUG MODE
-- ==========================
local DEBUG = false
local function debugPrint(msg)
    if DEBUG then print("[DEBUG] " .. msg) end
end

-- ==========================
-- FINDS MODEMS
-- ==========================
local modem, modemSide
for _, side in ipairs({"left", "right", "top", "bottom", "front", "back"}) do
    local p = peripheral.wrap(side)
    if p and peripheral.getType(side) == "modem" then
        modem = p
        modemSide = side
        break
    end
end
 
if not modem then
    term.setTextColor(colors.red)
    print("No modem detected on any side. Please attach a modem and restart.")
    term.setTextColor(colors.white)
    return
else
    term.setTextColor(colors.green)
    print("Modem found on side: "..modemSide)
    term.setTextColor(colors.white)
end
 
local PRIVATE_CHANNEL = os.getComputerID()
modem.open(1)
modem.open(PRIVATE_CHANNEL)

-- CONFIGURATION VARIABLES
local IP_FILE = "ip.txt" -- the name of the IP text file for loading/saving
local myIP
local routerChannel = 1
local SERVERNAME = "placeholder.lua" -- For ensure startup replace 'placeholder' with your server's name

-- ==========================
-- LOAD OR CREATE IP
-- ==========================
if not fs.exists(IP_FILE) then
    local f = fs.open(IP_FILE,"w")
    f.writeLine("")
    f.close()
    term.setTextColor(colors.red)
    print(IP_FILE.." created. Use CLI command 'set ip <ip>' to assign IP")
    term.setTextColor(colors.white)
    myIP = nil
else
    local f = fs.open(IP_FILE,"r")
    myIP = f.readLine()
    f.close()
    if myIP=="" then myIP=nil end
end

local function saveIP()
    local f = fs.open(IP_FILE,"w")
    f.writeLine(myIP)
    f.close()
end

-- ==========================
-- PACKET UTILITIES
-- ==========================
local seq = 0
local function makeUID()
    seq = seq + 1
    return tostring(seq).."-"..tostring(os.getComputerID())
end

local function sendPacket(dst,payload)
    if not myIP then
        print("Set your IP first with 'set ip <ip>' before sending packets.")
        return
    end
    local packet = { uid=makeUID(), src=myIP, dst=resolved, ttl=8, payload=payload }
    modem.transmit(routerChannel, PRIVATE_CHANNEL, packet)
end

-- HELLO_REPLY
local function replyHello(requester, private_channel)
    if not myIP then return end
    sendPacket(requester,{
        type = "HELLO_REPLY",
        private_channel = PRIVATE_CHANNEL
    })
    debugPrint("Replied to HELLO_REQUEST from "..requester)
    if private_channel and routerChannel == 1 then
        routerChannel = private_channel
        debugPrint("Router channel set to "..routerChannel)
    end
end

local function switchReply(side, packet)
    local payload = packet.payload
    -- Only respond if this is a switch hello from a switch
    if not payload.switch then return end
    -- Make sure the client has an IP
    if not myIP then
        debugPrint("Received S_H from switch but server IP is not set, ignoring.")
        return
    end
    -- Respond to switch with our IP and private channel
    local response = {
        type = "S_H",
        switch = false,          -- client, not a switch
        src_ip = myIP,
        private_channel = PRIVATE_CHANNEL -- or whatever channel we learned from HELLO
    }
	routerChannel = payload.private_channel --Will ALWAYS override the router channel to account for network expansion
    -- Send back to the switch using the port we received from
    sendPacket(packet.src, response)
    debugPrint("Responded to S_H from switch " .. tostring(packet.src) .. " with IP " .. myIP)
end
-- ==========================
-- RECEIVE LOOP
-- ==========================
local function receiveLoop()
    while true do
        local e, side, ch, reply, message, dist = os.pullEvent("modem_message")
        if type(message)=="table" and myIP and (message.dst==myIP or message.dst=="0") then
            local payload = message.payload
            if type(payload)~="table" then
                debugPrint("Invalid payload from "..tostring(message.src))
            else
                if payload.type == "HELLO_REQUEST" then
                    replyHello(message.src, payload.private_channel)
                elseif payload.type == "S_H" then
                    switchReply(side,message)
                    routerChannel = payload.private_channel -- Always overrides previous routerchannel to make network expansion easier
                elseif payload.type == "PING" then
                    debugPrint("Received PING from "..message.src)
                    sendPacket(message.src,{ type="PING_REPLY", message="pong" })
                else
                    debugPrint(("Message from %s: %s"):format(message.src, textutils.serialize(payload)))
                end
            end
        end
    end
end
-- ==========================
-- CLI LOOP
-- ==========================
local function cliLoop()
    print("Server ready. Commands: set ip <ip>, set password <password>, ip, list hosts, exit")
    while true do
        io.write("> ")
        local line = io.read()
        if not line then break end
        local args = {}
        for word in line:gmatch("%S+") do table.insert(args,word) end
        local cmd = args[1]
        if cmd=="exit" then return
        elseif cmd=="set" and args[2]=="ip" and args[3] then
            myIP=args[3]; saveIP(); print("IP set to "..myIP)
        elseif cmd=="ip" then print("Current IP: "..tostring(myIP))
        elseif cmd=="debugmode" and args[2] then
            if args[2] == "true" then
                DEBUG = true
           	elseif args[2] == "false" then
                DEBUG = false
			end
        else
            print("Commands: set ip <ip>, set password <password>, ip, list hosts, exit")
        end
    end
end

-- START SERVER
-- autostart setup
local function ensureStartup()
    local startupContent = ""
    if fs.exists("startup") then
        local f = fs.open("startup","r")
        startupContent = f.readAll()
        f.close()
    end
    if not startupContent:match("shell%.run%(\'"..SERVERNAME.."\'%)") then
        local f = fs.open("startup","a")
        f.writeLine("shell.run('"..SERVERNAME.."')")
        f.close()
    end
end

ensureStartup()

if not fs.exists(FILE_DIR) then fs.makeDir(FILE_DIR) end
parallel.waitForAny(receiveLoop, cliLoop)
