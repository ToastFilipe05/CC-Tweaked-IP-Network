-- client.lua Version 1.8
-- Compatible with HostServer 1.1+ diff update system
-- Compatible with Switch 2.0 S_H (switch hello) discovery system
-- CC:Tweaked wired client for IP router & server systems
-- Supports hostname keywords, HELLO_REPLY only, secure plaintext file transfer, standardized IP file
-- Automatic multishell self-launch and host sync updates
-- Multi-channel system support
-- startup file automatically added

-- DEBUG MODE

local C = {}

local DEBUG = false
local function debugPrint(msg)
    if DEBUG then print("[DEBUG] " .. msg) end
end


-- NETWORK CONFIG
local routerChannel = 1
local PRIVATE_CHANNEL = os.getComputerID()
-- Try to automatically find a connected modem
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

modem.open(1)
modem.open(PRIVATE_CHANNEL)

local IP_FILE = "Configs/ip.txt"
local HOSTS_FILE = "Configs/hosts.txt"
local SERVER_FILE = "Configs/host_server_ip.txt"

local myIP
local hosts = {}
local hostServerIP = "201.200.10.1"

-- IP MANAGEMENT

if not fs.exists(IP_FILE) then
    local f = fs.open(IP_FILE,"w") f.writeLine("") f.close()
    term.setTextColor(colors.yellow)
    print(IP_FILE.." created. Use CLI command 'set ip <ip>' to assign IP before networking.")
    term.setTextColor(colors.white)
else
    local f = fs.open(IP_FILE,"r")
    myIP = f.readLine()
    f.close()
    if myIP == "" then myIP = nil end
end

local function saveIP()
    local f = fs.open(IP_FILE,"w")
    f.writeLine(myIP or "")
    f.close()
end

-- HOSTS MANAGEMENT
local function loadHosts()
    if fs.exists(HOSTS_FILE) then
        local f = fs.open(HOSTS_FILE, "r")
        local data = f.readAll()
        f.close()
        if data and data ~= "" then
            local ok, t = pcall(textutils.unserialize, data)
            if ok and type(t) == "table" then
                hosts = t
                debugPrint("Loaded " .. tostring(#(hosts or {})) .. " hosts.")
                return
            end
        end
    end
    hosts = {}
end

local function saveHosts()
    local f = fs.open(HOSTS_FILE, "w")
    f.writeLine(textutils.serialize(hosts))
    f.close()
end

-- Initialize hosts.txt if missing
if not fs.exists(HOSTS_FILE) then
    local f = fs.open(HOSTS_FILE, "w")
    f.writeLine(textutils.serialize({}))
    f.close()
    term.setTextColor(colors.yellow)
    print("hosts.txt created. Awaiting synchronization from host server.")
    term.setTextColor(colors.white)
end
loadHosts()


-- HOST SERVER DISCOVERY
local function saveServerIP()
    local f = fs.open(SERVER_FILE, "w")
    f.writeLine(hostServerIP or "")
    f.close()
end

local function loadServerIP()
    if fs.exists(SERVER_FILE) then
        local f = fs.open(SERVER_FILE, "r")
        hostServerIP = f.readLine()
        f.close()
    end
end
loadServerIP()

-- PACKET UTILITIES
local seq = 0
local function makeUID()
	seq = seq+1
    return tostring(seq).."-"..tostring(os.getComputerID())
end

local function resolveAddress(input)
    if hosts[input] and hosts[input].ip then return hosts[input].ip end
    return input
end

local function sendPacket(dst, payload)
    if not myIP then
        term.setTextColor(colors.yellow)
        print("Set your IP first with 'set ip <ip>' before sending packets.")
        term.setTextColor(colors.white)
        return
    end
    local resolved = resolveAddress(dst)
    if not resolved then
        term.setTextColor(colors.red)
        print("Unknown destination: "..tostring(dst))
        term.setTextColor(colors.white)
        return
    end
    local packet = { uid=makeUID(), src=myIP, dst=resolved, ttl=8, payload=payload }
    modem.transmit(routerChannel, PRIVATE_CHANNEL, packet)
    debugPrint("Sent packet to "..dst.." on channel "..routerChannel)
end

local function broadcast(payload)
    local packet = { uid=makeUID(), src=myIP or "unknown", dst="0", ttl=8, payload=payload }
    modem.transmit(1,1,packet)
end

-- HELLO REPLY
local function replyHello(requester)
    if not myIP then return end
    sendPacket(requester, { type="HELLO_REPLY", private_channel = PRIVATE_CHANNEL })
    debugPrint("Replied to HELLO_REQUEST from "..requester)
end

local function switchReply(side,packet)
    -- Only respond if this is a switch hello from a switch
    local payload = packet.payload
    if not payload.switch then return end
    -- Make sure the client has an IP
    if not myIP then
        debugPrint("Received S_H from switch but client IP is not set, ignoring.")
        return
    end
    -- Respond to switch with our IP and private channel
    local response = {
        type = "S_H",
        switch = false,          -- client, not a switch
        private_channel = PRIVATE_CHANNEL
    }
	--ALWAYS set router channel to switches private channel for easier network expansion
	routerChannel = payload.private_channel
    -- Send back to the switch using the port we received from
    sendPacket(packet.src, response)
    debugPrint("Responded to S_H from switch " .. tostring(packet.src) .. " with IP " .. myIP)
end

-- FILE TRANSFER
local receivingFile = false
local fileBuffer = {}
local expectedChunks = 0
local fileNameBeingReceived = ""
local requestedFile = ""

local function requestFile(dst, filename)
    print("Requesting file '" .. filename .. "' from " .. dst .. " (" .. resolveAddress(dst) ..")")
    sendPacket(dst, { type="FILE_REQUEST", filename=filename })
end

function C.sendACK(serverKeyword, password)
	local dst = resolveAddress(serverKeyword)
    if not dst then
        print("Nil value for address, try again")
        print("You entered: " .. serverKeyword .. " translated to " .. dst)
        return
    end
    if not dst:match("^%d+%.%d+%.%d+%.%d+$") then print("Unknown server keyword "..serverKeyword) return
    else 
        term.setTextColor(colors.blue)
        print("Establishing Connection to " .. serverKeyword .. " (" .. dst .. ") if no response within max 60 seconds assume no connection, try ping to test connection manually")
        term.setTextColor(colors.white)
    	sendPacket(dst, { type="ACK_START", password = password })
	end
end

-- HOST UPDATE HANDLING
local function handleUpdateHosts(payload)
    if type(payload.hosts) == "table" then
        hosts = payload.hosts
        saveHosts()
        debugPrint("[HostSync] Full hosts list updated.")
    end
end

local function handleHostsDiff(payload)
    local diff = payload.diff
    if not diff then return end

    for _, name in ipairs(diff.removed or {}) do hosts[name] = nil end
    for name, info in pairs(diff.added or {}) do hosts[name] = info end
    for name, info in pairs(diff.updated or {}) do hosts[name] = info end
    saveHosts()
    debugPrint("[HostSync] Hosts diff applied.")
end

local function discoverHostServer()
    debugPrint("[HostSync] Discovering host server...")
    broadcast({ type="DISCOVER_HOST_SERVER" })
end

function C.requestFullHosts()
    if hostServerIP then
        debugPrint("[HostSync] Requesting full host table from " .. hostServerIP)
        sendPacket(hostServerIP, { type="REQUEST_HOSTS" })
    else
        discoverHostServer()
    end
end

-- RECEIVE LOOP
function C.receiveLoop()
    while true do
        local _, _, _, _, message = os.pullEvent("modem_message")
        debugPrint("Recieved packet " .. textutils.serialize(message) .. " attempting to handle")
        if type(message) == "table" and type(message.payload) == "table" and (message.dst == myIP or message.dst == "0") then
            local payload = message.payload

            if payload.type == "HELLO_REQUEST" then -- Router Discovery 
    			if payload.private_channel and type(payload.private_channel) == "number" then
                    if routerChannel == 1 then
        				routerChannel = payload.private_channel
        				debugPrint("Learned router channel: " .. routerChannel)
                    end
    			end
    			replyHello(message.src)
            elseif payload.type == "S_H" then --Switch hello packet for switch discovery
					switchReply(modemSide, message)
                	debugPrint("recieved Switch Hello packet")
            elseif payload.type == "FILE_CHUNK" then -- holds a section of a file transfer
                if not receivingFile then
                    receivingFile = true
                    fileBuffer = {}
                    expectedChunks = payload.total or 1
                    fileNameBeingReceived = payload.filename or ("unknown_"..makeUID())
                    print("Receiving file "..fileNameBeingReceived.." ("..expectedChunks.." chunks)")
                end
                fileBuffer[payload.seq] = payload.data
                if payload.seq % 5 == 0 or payload.seq == expectedChunks then
                    print("Received chunk "..payload.seq.."/"..expectedChunks)
                end
            elseif payload.type == "FILE_END" then -- flags the end of a file transfer and builds the file chucks together
    			local tbl = {}
    			for i=1,(expectedChunks or #fileBuffer) do
        			table.insert(tbl, fileBuffer[i] or "")
    			end
    			local data = table.concat(tbl)
                local out = fs.open(fileNameBeingReceived, "w")
                if out then
                    out.write(data) out.close()
                    print("File '"..fileNameBeingReceived.."' saved successfully.")
                else
                    term.setTextColor(colors.red)
                    print("Failed to write file: "..fileNameBeingReceived)
                    term.setTextColor(colors.white)
                end
                receivingFile, fileBuffer, expectedChunks, fileNameBeingReceived, requestedFile = false, {}, 0, "", ""
            elseif payload.type == "ERROR" then -- Error during a file trasfer or any other kind of message
                term.setTextColor(colors.red)
                print("Packet Error: "..(payload.message or "Unknown"))
                term.setTextColor(colors.white)
            elseif payload.type == "ACK" then -- ACK packet for file transfer (can be rebuilt if you want more than just file trasfer)
    			term.setTextColor(colors.blue)
    			print("ACK received, starting FTP")
    			term.setTextColor(colors.white)
    			if requestedFile and requestedFile ~= "" then
        			requestFile(message.src, requestedFile)
    			else
                    term.setTextColor(colors.red)
        			print("ACK received but no requestedFile set.")
                    term.setTextColor(colors.white)
    			end
            elseif payload.type == "PING" then --Ping handling
                sendPacket(message.src,{ type="PING_REPLY", message="pong" })
            elseif payload.type == "PING_REPLY" then
                print("Reply from "..message.src..": "..(payload.message or "pong"))
            elseif payload.type == "UPDATE_HOSTS" then --Updates Host name translations by overriding the current hosts.txt
                handleUpdateHosts(payload)
            elseif payload.type == "HOSTS_DIFF" then --Updates Host name translations by adding, removing, or editing hosts.txt
                handleHostsDiff(payload)
            elseif payload.type == "HOST_SERVER_HERE" then -- Remembers host server IP
                if payload.server_ip then
                    hostServerIP = payload.server_ip
                    saveServerIP()
                    debugPrint("[HostSync] Host server discovered at " .. hostServerIP)
                    C.requestFullHosts()
                end
            else --Packet isn't handled by client.lua (other files could handle the packet though)
                debugPrint("Unhandled packet: "..textutils.serialize(payload))
            end
        end
    end
end

-- CLI LOOP
local colorsList = { colors.cyan, colors.yellow, colors.green, colors.magenta }

local function printCommands() -- prints commands with different colors
    local cmds = {
        "set ip <ip>",
        "ping <host>",
        "getfile <server> <filename> <password>",
        "list hosts",
        "sync hosts",
        "ip",
        "exit",
        "debugmode <true|false>"
    }
    print("Client ready. Commands:")
    for i, cmd in ipairs(cmds) do
        term.setTextColor(colorsList[(i-1)%#colorsList+1])
        print("  "..cmd)
    end
    term.setTextColor(colors.white)
end

function C.cliLoop() --Command Line Interface loop
    printCommands()
    while true do
        io.write("> ")
        local line = io.read()
        if not line then break end
        local args = {}
        for word in line:gmatch("%S+") do table.insert(args, word) end
        local cmd = args[1]
        if cmd == "exit" then return
        elseif cmd == "set" and args[2] == "ip" and args[3] then
            myIP = args[3]; saveIP(); print("IP set to "..myIP)
        elseif cmd == "ping" and args[2] then
            sendPacket(args[2], { type="PING" }); print("Ping sent to "..args[2])
        elseif cmd == "list" and args[2] == "hosts" then
            print("Known hosts:")
            for k,v in pairs(hosts) do
                print(("  %-10s -> %s"):format(k, v.ip or "??"))
            end
        elseif cmd == "sync" and args[2] == "hosts" then
            C.requestFullHosts()
        elseif cmd == "getfile" and args[2] and args[3] and args[4] then
            C.sendACK(args[2], args[4])
            requestedFile = args[3]
        elseif cmd == "ip" then
            print("Current IP: "..tostring(myIP))
        elseif cmd == "debugmode" and args[2] then
    		if args[2] == "false" then
        		DEBUG = false; print("Debug mode OFF")
    		elseif args[2] == "true" then
        		DEBUG = true; print("Debug mode ON")

            else
            	term.setTextColor(colors.red)
            	print("Error: Unrecognized argument | useage: debugmode true || debugmode false")
            	term.setTextColor(colors.white)
            end
        else
            term.setTextColor(colors.red)
            print("Error: Unrecognized command")
            term.setTextColor(colors.white)
            printCommands()
        end
    end
end

-- STARTUP

-- autostart setup
local function ensureStartup()
    local startupContent = ""
    if fs.exists("startup") then
        local f = fs.open("startup","r")
        startupContent = f.readAll()
        f.close()
    end
    if not startupContent:match("shell%.run%(\'clientGUI.lua\'%)") then
        local f = fs.open("startup","a")
        f.writeLine("shell.run('clientGUI.lua')")
        f.close()
    end
end

ensureStartup()

if not hostServerIP then 
    discoverHostServer() 
else 
    C.requestFullHosts() 
end -- Makes sure that it's hosts.txt is updated fully on boot

--Getters and Setters
-- Getter for myIP
function C.getIP()
    return myIP
end
-- Setter for myIP
function C.setIP(IP)
    myIP = IP
    saveIP()
end
-- Getter for Hosts
function C.getHosts()
    return hosts
end
-- Getter for Host Server IP
function C.getHostSvrIP()
    return hostServerIP
end
-- Setter for Host Server IP
function C.setHostSvrIP(IP)
    hostServerIP = IP
    saveServerIP()
end
-- Getter for router channel
function C.getRouterChannel()
    return routerChannel
end

return C
