local function update(filename, webpage)
	if fs.exists(filename) then
		fs.delete(filename)
		print("Deleted old "..filename)
	else
		print(filename.."not found. Installing "..filename)
	end

	shell.run("wget "..webpage.." "..filename)
	print("Downloaded latest "..filename)
end

local function cliLoop()
    term.setTextColor(colors.red)
    print("UPDATER MUST BE RAN IN SAME DIR AS FILE YOU WANT TO UPDATE")
    term.setTextColor(colors.white)
    print("Updater ready. Command arguments:")
    print("router, client, switch, fileServer, hostServer, updater, cellTower, wirelessClient")
    while true do
       	term.setTextColor(colors.yellow)
        io.write("> ")
        term.setTextColor(colors.white)
        local line = io.read()
        if not line then break end
        local args = {}
        for word in line:gmatch("%S+") do table.insert(args, word) end
        local cmd = args[1]
        if cmd=="router" then
       		update("router.lua","https://raw.githubusercontent.com/ToasterOvenDev/CC-Tweaked-IP-Network/refs/heads/main/WiredNetwork/Router.lua")
			print("Routers can also be run with servers installed. Please update any server files on device.")
			break
        elseif cmd=="client" then
       		update("client.lua", "https://raw.githubusercontent.com/ToasterOvenDev/CC-Tweaked-IP-Network/refs/heads/main/WiredNetwork/Client.lua")
			break
		elseif cmd=="wirelessClient" then
        	update("wirelessClient.lua","https://raw.githubusercontent.com/ToasterOvenDev/CC-Tweaked-IP-Network/refs/heads/main/WirelessNetwork/wirelessClient.lua")
			break
        elseif cmd=="switch" then
            update("switch.lua","https://raw.githubusercontent.com/ToasterOvenDev/CC-Tweaked-IP-Network/refs/heads/main/WiredNetwork/switch.lua")
			break
        elseif cmd=="fileServer" then
            update("fileServer.lua","https://raw.githubusercontent.com/ToasterOvenDev/CC-Tweaked-IP-Network/refs/heads/main/WiredNetwork/FileServer.lua")
			break
        elseif cmd=="hostServer" then
            update("hostServer.lua","https://raw.githubusercontent.com/ToasterOvenDev/CC-Tweaked-IP-Network/refs/heads/main/WiredNetwork/hostServer.lua")
			break
		elseif cmd=="cellTower" then
            update("cellTower.lua","https://raw.githubusercontent.com/ToasterOvenDev/CC-Tweaked-IP-Network/refs/heads/main/WirelessNetwork/cellTower.lua")
			break
        elseif cmd=="updater" then
            update("updater.lua","https://raw.githubusercontent.com/ToasterOvenDev/CC-Tweaked-IP-Network/refs/heads/main/UtilityFiles/Updater.lua")
			break
        elseif cmd=="quit" then
            break
        else
           	print("Usage: router | client | switch | fileServer | hostServer | updater | cellTower | wirelessClient | quit") 
        end
    end
end

cliLoop()
