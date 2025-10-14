-- fileServer.lua Version 1.1
-- CC:Tweaked server for file sharing with password protection
-- Uses HELLO_REPLY only, auto IP and password files

local modemSide = "back"
local modem = peripheral.wrap(modemSide)
modem.open(1)

-- ==========================
-- CONFIGURATION
-- ==========================
local CHUNK_SIZE = 512
local IP_FILE = "ip.txt"
local PASSWORD_FILE = "server_password.txt"

-- ==========================
-- STATE
-- ==========================
local hosts = {}
local myIP
local SERVER_PASSWORD

-- ==========================
-- LOAD OR CREATE IP
-- ==========================
if not fs.exists(IP_FILE) then
    local f = fs.open(IP_FILE,"w")
    f.writeLine("")
    f.close()
    print(IP_FILE.." created. Use CLI command 'set ip <ip>' to assign IP before networking.")
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
-- LOAD OR CREATE SERVER PASSWORD
-- ==========================
if not fs.exists(PASSWORD_FILE) then
    local f = fs.open(PASSWORD_FILE,"w")
    f.writeLine("")
    f.close()
    print(PASSWORD_FILE.." created. Use CLI command 'set password <password>' to assign a server password.")
    SERVER_PASSWORD = nil
else
    local f = fs.open(PASSWORD_FILE,"r")
    SERVER_PASSWORD = f.readLine()
    f.close()
    if SERVER_PASSWORD=="" then SERVER_PASSWORD=nil end
end

local function savePassword()
    local f = fs.open(PASSWORD_FILE,"w")
    f.writeLine(SERVER_PASSWORD)
    f.close()
end

-- ==========================
-- LOAD HOSTS KEYWORDS
-- ==========================
if fs.exists("hosts.txt") then
    local file = fs.open("hosts.txt","r")
    while true do
        local line = file.readLine()
        if not line then break end
        local key, ip = line:match("^(%S+)%s+(%S+)$")
        if key and ip then hosts[key]=ip end
    end
    file.close()
end

-- ==========================
-- PACKET UTILITIES
-- ==========================
local seq = 0
local function makeUID()
    seq = seq + 1
    return tostring(os.time()).."-"..tostring(seq)
end

local function sendPacket(dst,payload)
    if not myIP then
        print("Set your IP first with 'set ip <ip>' before sending packets.")
        return
    end
    local resolved = hosts[dst] or dst
    if not resolved then
        print("Unknown destination: "..tostring(dst))
        return
    end
    local packet = { uid=makeUID(), src=myIP, dst=resolved, ttl=8, payload=payload }
    modem.transmit(1,1,packet)
end

-- ==========================
-- HELLO_REPLY (triggered by router)
-- ==========================
local function replyHello(requester)
    if not myIP then return end
    sendPacket(requester,{ type="HELLO_REPLY" })
    print("Replied to HELLO_REQUEST from "..requester)
end

-- ==========================
-- FILE TRANSFER FUNCTIONS
-- ==========================
local function sendFile(dst, filename)
    if not fs.exists(filename) then
        print("File does not exist: "..filename)
        return
    end
    local f = fs.open(filename,"r")
    local data = f.readAll()
    f.close()
    local chunks={}
    for i=1,#data,CHUNK_SIZE do
        local chunk = data:sub(i, math.min(i+CHUNK_SIZE-1,#data))
        table.insert(chunks,chunk)
    end
    print("Sending file "..filename.." to "..dst.." in "..#chunks.." chunks")
    for i,chunk in ipairs(chunks) do
        sendPacket(dst,{ type="FILE_CHUNK", filename=filename, seq=i, total=#chunks, data=chunk })
    end
    sendPacket(dst,{ type="FILE_END", filename=filename })
    print("File "..filename.." sent successfully")
end

-- ==========================
-- RECEIVE LOOP
-- ==========================
local function receiveLoop()
    while true do
        local e, side, ch, reply, message, dist = os.pullEvent("modem_message")
        if type(message)=="table" and myIP and message.dst==myIP then
            local payload = message.payload
            if type(payload)~="table" then
                print("Invalid payload from "..tostring(message.src))
            else
                if payload.type=="HELLO_REQUEST" then
                    replyHello(message.src)
                elseif payload.type=="FILE_REQUEST" then
                    if not SERVER_PASSWORD then
                        print("No server password set. Cannot process file requests.")
                    elseif payload.password==SERVER_PASSWORD then
                        print("Received file request from "..message.src.." for "..payload.filename)
                        sendFile(message.src,payload.filename)
                    else
                        print("Invalid password from "..message.src.." for "..payload.filename)
                        sendPacket(message.src,{ type="ERROR", message="Invalid password" })
                    end
                elseif payload.type=="PING" then
                    print("Received PING from "..message.src)
                    sendPacket(message.src,{ type="PING_REPLY", message="pong" })
                else
                    print(("Message from %s: %s"):format(message.src, textutils.serialize(payload)))
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
        local args={}
        for word in line:gmatch("%S+") do table.insert(args,word) end
        local cmd=args[1]
        if cmd=="exit" then return
        elseif cmd=="set" and args[2]=="ip" and args[3] then
            myIP=args[3]; saveIP(); print("IP set to "..myIP)
        elseif cmd=="set" and args[2]=="password" and args[3] then
            SERVER_PASSWORD=args[3]; savePassword(); print("Server password set")
        elseif cmd=="ip" then print("Current IP: "..tostring(myIP))
        elseif cmd=="list" and args[2]=="hosts" then
            print("Known hosts:")
            for k,v in pairs(hosts) do print("  "..k.." -> "..v) end
        else
            print("Commands: set ip <ip>, set password <password>, ip, list hosts, exit")
        end
    end
end

-- ==========================
-- START SERVER
-- ==========================
parallel.waitForAny(receiveLoop, cliLoop)
