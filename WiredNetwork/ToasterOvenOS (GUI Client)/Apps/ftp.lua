package.path = package.path .. ";../Dependencies/?.lua"
local basalt = require("basalt")
local client = require("client")

local myPassword -- Password for peer to peer FTP
local myBNP = client.getBNP()
local FILE_DIR = "/Files/"


-- Need to create a list based on flags so that we can filter host results based on flags
local hosts = {} -- Hosts list from DNS Server (Host Server) or from local dir
local flagslist = {} -- List of flags that exist in ftp capable hosts other than "FTPSVR" or "FTP"
local ftpHosts = {} -- Filted version of hosts to only include FTP capable hosts, key = hostname value = flags table

local function reload()
    hosts = {} -- Empty hosts out
    client.requestFullHosts() -- Update hosts from DNS Server
    hosts = client.getHosts() -- Reload hosts
    flagslist = {} -- Empty out flagslist to get rid of old entries that may be gone
    ftpHosts = {} -- Empty out ftpHosts to get rid of old entries that may be gone
    -- Making a list that only includes FTP capable hosts
    for k in pairs(hosts) do
        for _, v in pairs(hosts[k].flags) do
            if v == "FTPSVR" or v == "FTP" then
                ftpHosts[k] = hosts[k].flags -- Pre-filtered for FTP list
            end
        end
    end
    -- Inserts all flags into a list for filtering later
    for k in pairs(ftpHosts) do
        for _, v in pairs(ftpHosts[k].flags) do
            if not flagslist[v] and v ~= "FTPSVR" or v ~= "FTP" then -- Filtering list for extra flags
                table.insert(flagslist,v)
            end
        end
    end

end

reload()

local gui = basalt.createFrame():setBackground(colors.cyan)
local hostlist = gui:addList():setBackground(colors.cyan)
for k,v in pairs(ftpHosts) do
    hostlist:addItem(k, colors.cyan, colors.black, v) -- List so Users know what hostname translations exist
end

gui:addLabel() -- Label for Host list
gui:addLabel() -- Label for requestee input
gui:addLabel() -- Label for File input
gui:addLabel() -- Label for Password input
gui:addLabel() -- Label for myPassword
gui:addLabel() -- Label for Accessable Files Dir
local ErrLabel = gui:addLabel() -- Label for Error messages

local requesteeInput = gui:addInput()


local fileInput = gui:addInput()


local password = gui:addInput()



local myPassword = gui:addInput()


local filesDir = gui:addInput()

local function sendFile(dst, filename)
    local fullPath = FILE_DIR..filename
    if not fs.exists(fullPath) then
        ErrLabel:setText("File not found, aborting file send")
        return
    else
        ErrLabel:setText("Sending ".. filename .." to " .. dst)
    end

    local f = fs.open(fullPath,"r")
    local data = f.readAll()
    f.close()

    local chunks = {}
    for i=1,#data,512 do
        local chunk = data:sub(i, math.min(i+512-1,#data))
        table.insert(chunks,chunk)
    end

    for i,chunk in ipairs(chunks) do
        client.sendPacket(dst,{ type="FILE_CHUNK", filename=filename, seq=i, total=#chunks, data=chunk })
    end
    client.sendPacket(dst,{ type="FILE_END", filename=filename })
end

local function listener()
    while true do
        local e, side, ch, reply, message, dist = os.pullEvent("modem_message")
        if type(message)=="table" and myBNP and (message.dst==myBNP or message.dst=="0") then
            local payload = message.payload
            if type(payload)~="table" then
                return
            else
                if payload.type == "ACK_START" then -- A client is trying to establish a connection to transfer a file
                    if not myPassword then
                        ErrLabel:setText("No password set peers can't access files")
                        client.sendPacket(message.src,{ type="ERROR", message="Peer has no password, try messaging them!" })
                    elseif payload.password == myPassword then
                        ErrLabel:setText("Peer trying to establish a connection to download a file, sending an ACK")
                        client.sendPacket(message.src,{ type="ACK" })
                    else
                        client.sendPacket(message.src,{ type="ERROR", message="Invalid password" })
                    end
                elseif payload.type == "ERROR" then -- Error during a file trasfer or any other kind of message
                    ErrLabel:setText("Packet Error: "..(payload.message or "Unknown"))
                elseif payload.type == "FILE_REQUEST" then -- AcK handshake has completed and the file is started to be sent
                    ErrLabel:setText("Peer established a connection and is requesting " .. payload.filename .. " Attempting to send file...")
                    sendFile(message.src,payload.filename)
                else
                    return -- Otherfiles might handle
                end
            end
        end
    end
end





