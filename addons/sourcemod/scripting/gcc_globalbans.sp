#include <sourcemod>

// Optional Includes
#undef REQUIRE_PLUGIN
#undef REQUIRE_EXTENSIONS
#include <socket>
#include <SteamWorks>
#define REQUIRE_PLUGIN
#define REQUIRE_EXTENSIONS

// Compile Options
#pragma newdecls required
#pragma semicolon 1
 
#define API_URL "charlesbar.one"
#define API_PATH "/gcc/"
 
public Plugin myinfo =
{
    name = "Gaming Community Central: Global Ban System",
    author = "Charles_(hypnos) | Thomasjosif",
    description = "Globally removing cheaters 1 ban at a time.",
    version = "1.0.0",
    url = "https://github.com/CharlesBarone"
};
 
// Global Values
char g_sCommunityName[MAX_NAME_LENGTH];
char g_sAppId[10];

bool g_bSocket = false;
bool g_bSteamWorks = false;
bool g_bReCheck[MAXPLAYERS+1] = false;

// ConVar Values
ConVar gc_bEnableFamilyShare;
ConVar gc_sCommunityName;

// ########################################################################################
// ####################################### FORWARDS #######################################
// ########################################################################################

public void OnPluginStart()
{
    CheckAvailableExtensions();
    GrapAppId();
    
    gc_bEnableFamilyShare = CreateConVar("sm_gcc_family_share", "1", "0 - disabled, 1 - enable Family Sharing global bans for players on the global ban list (default)", _, true, 0.0, true, 1.0);
    gc_sCommunityName = CreateConVar("sm_gcc_community_name", "DEFAULT_NAME", "Set your community name to ignore your own bans.");
    
    AutoExecConfig(true);
}

public void OnConfigsExecuted()
{
    // Make sure we have a valid community name.
    gc_sCommunityName.GetString(g_sCommunityName, sizeof(g_sCommunityName));
    if (StrEqual(g_sCommunityName, "DEFAULT_NAME", true))
        SetFailState("Community name not defined. User ConVar: sm_gcc_community_name located in autoexec file.");
}


public void OnClientAuthorized(int client, const char[] sAuth)
{
    // Ignores bots and lan users.
    if (StrEqual(sAuth, "BOT", false) || StrEqual(sAuth, "STEAM_ID_LAN", false))
        return;
    
    else
    {
        char sSteamid[32];
        
        // Is that steamid really valid?
        if (!GetClientAuthId(client, AuthId_Steam2, sSteamid, sizeof(sSteamid))) 
            g_bReCheck[client] = true;
        else
            ValidatePlayer(client, sSteamid);
    }
}

public void OnClientPostAdminCheck(int client)
{
    // This should NEVER happen, but you never know. Good to be on the safe side.
    if(g_bReCheck[client])
    {
        char sSteamID[32];
        if(GetClientAuthId(client, AuthId_Steam2, sSteamID, sizeof(sSteamID)))
            ValidatePlayer(client, sSteamID);
            
        else
            LogError("OnClientPostAdminCheck :: Failed to verify users ban status after two attempts.");
    }
}

public void OnClientDisconnect(int client)
{
    g_bReCheck[client] = false;
}

/**
 * Family Sharing for Global Bans (SteamWorks)
 * @note This will only be called if steamworks is loaded.
 *
 * @param ownerSteam     The owner's steamid.
 * @param clientSteam    The client's steamid.
 * @noreturn
 */
public int SteamWorks_OnValidateClient(int ownerSteam, int clientSteam)
{
    if (ownerSteam && ownerSteam != clientSteam)
    {
        char sOwnerSteamid[32];
        Format(sOwnerSteamid, sizeof(sOwnerSteamid), "STEAM_0:%d:%d", ownerSteam & 1, ownerSteam >> 1);

        int client;

        for (int i = 1; i <= MaxClients; i++) 
        {
            if (IsClientConnected(i))
            {
                if (GetSteamAccountID(i) == clientSteam)
                {
                    client = i;
                    break;
                }
            }
        }

        // Validate the player with the owner's steamid.
        if (client > -1)
            ValidatePlayer(client, sOwnerSteamid, true);
    }
}

// ####################################################################################
// ################################### WEB CALLBACKS ##################################
// ####################################################################################

/**
 * Socket Connect Callback
 * @note This will only be called if socket is loaded.
 *
 * @param hSocket     Request handle.
 * @param hPack       Datapack.
 * @noreturn
 */
public int SocketCB_Connected(Handle hSocket, any hPack)
{
    if(SocketIsConnected(hSocket))  // If socket is connected, should be since this is the callback that is called if it is connected
    {
        char sSteamID[32];
        // Unpack our data
        DataPack pack = view_as<DataPack>(hPack);
        pack.Reset();
        pack.ReadString(sSteamID, sizeof(sSteamID));
        pack.ReadCell(); // client variable. Discarded.
        
        // Buffers
        char sRequestString[1000], sRequestParams[320];
        /*URLEncode(g_sCommunityName, sizeof(g_sCommunityName));
        URLEncode(sSteamID, sizeof(sSteamID));*/
        Format(sRequestParams, sizeof(sRequestParams), "%s.php?COMMUNITY=%s&STEAMID=%s&APPID=%s", !pack.ReadCell() ? "master" : "shared", g_sCommunityName, sSteamID, g_sAppId);
        Format(sRequestString, sizeof(sRequestString), "GET %s/%s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n", API_PATH, sRequestParams, API_URL); // Request String
        SocketSend(hSocket, sRequestString);    // Send the request
    }
}

/**
 * Socket Recive Callback
 * @note This will only be called if socket is loaded.
 *
 * @param hSocket     Request handle.
 * @param sData       Response data.
 * @param iSize       Response size.
 * @param hPack       Datapack.
 * @noreturn
 */
public int SocketCB_Recieve(Handle hSocket, char[] sData, const int iSize, any hPack)
{
    if(hSocket != null)
    {  
        char sSteamID[32];
        // Unpack our data
        DataPack pack = view_as<DataPack>(hPack);
        pack.Reset();
        pack.ReadString(sSteamID, sizeof(sSteamID));
        int client = pack.ReadCell();
        bool family = pack.ReadCell();
                
        // This is a family sharing check.
        if(family)
        {
            // We have an invalid response.
            if((StrEqual(sData, "") || strlen(sData) < 3 || StrContains(sData, "-") > -1) && !StrEqual(sData, "0"))
                LogError("ERROR in SocketCB_Recieve :: response sent invalid data for family check! DATA: %s", sData);
                
            // Validate the player with the owner's steamid.
            else if (!StrEqual(sData, "0"))
                ValidatePlayer(client, sData, true);
        }
        // Kick player.
        else if(StrContains(sData, "OK", true) == -1)
            GCC_KickPlayer(client, sData);
 
        if(SocketIsConnected(hSocket))  // Close the socket
            SocketDisconnect(hSocket);
    }
}

/**
 * Socket Disconnect Callback
 * @note This will only be called if socket is loaded.
 *
 * @param hSocket         Request handle.
 * @param hPack           Datapack.
 * @noreturn
 */ 
public int SocketCB_Disconnect(Handle hSocket, any hPack)
{
    if(hSocket != null)
        CloseHandle(hSocket);
}

/**
 * Socket Error Callback
 * @note This will only be called if socket is loaded.
 *
 * @param hSocket         Request handle.
 * @param iErrorType      Error type.
 * @param iErrorNum       Error number.
 * @param hPack           Datapack.
 * @noreturn
 */
public int OnSocketError(Handle hSocket, const int iErrorType, const int iErrorNum, any hPack)
{
    LogError("Socket error type %i ; Error number %i", iErrorType, iErrorNum);
   
    if(hSocket != null)
        CloseHandle(hSocket);
}

/**
 * Data recived from the SteamWorks ValidatePlayer call.
 * @note This will only be called if steamworks is loaded.
 *
 * @param request               Request handle.
 * @param failure               True on failure of request.
 * @param requestSuccessful     True on successful request.
 * @param statusCode            HTTP Status code of request.
 * @param data                  Datapack.
 * @noreturn
 */
public int SteamWorks_OnDataReceive(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode statusCode, Handle hData)
{
    char sSteamID[32];
    
    // Web response
    if(!bFailure && bRequestSuccessful && statusCode == k_EHTTPStatusCode200OK)
    {
        // Unpack our data
        DataPack pack = view_as<DataPack>(hData);
        pack.Reset();
        pack.ReadString(sSteamID, sizeof(sSteamID));
        int client = pack.ReadCell();
        
        // Get web response as a string.
        int iSize = 0;
        SteamWorks_GetHTTPResponseBodySize(hRequest, iSize);
        char[] sResponse = new char[iSize];
        SteamWorks_GetHTTPResponseBodyData(hRequest, sResponse, iSize);
        
        // Kick player.
        if(StrContains(sResponse, "OK", true) == -1)
            GCC_KickPlayer(client, sResponse);
    }
    // Delete handle
    delete hRequest;
    
    return;
}

// ########################################################################################
// ######################################## STOCKS ########################################
// ########################################################################################

/**
 * Validates player with whichever extension is loaded.
 *
 * @param client        Client index.
 * @param sSteamID      Steamid to send to callbacks.
 * @param bFamilyCheck   True when this is a family check validation.
 * @noreturn
 */
stock void ValidatePlayer(int client, char[] sSteamID = "", bool bFamilyCheck = false)
{
    // Data for later.
    DataPack pack = new DataPack();
    pack.WriteString(sSteamID);
    pack.WriteCell(client);
    
    // Socket is defualt unless we are doing family checks. (Steamworks is more efficient for family checking.)
    if(g_bSocket && !(g_bSteamWorks && gc_bEnableFamilyShare.BoolValue))
    {
        if(gc_bEnableFamilyShare.BoolValue && !bFamilyCheck)
            pack.WriteCell(true);
        else
            pack.WriteCell(false);
            
        Handle Socket = SocketCreate(SOCKET_TCP, OnSocketError);
        SocketSetOption(Socket, ConcatenateCallbacks, 4096);
        SocketSetOption(Socket, SocketReceiveTimeout, 3);
        SocketSetOption(Socket, SocketSendTimeout, 3);
        SocketConnect(Socket, SocketCB_Connected, SocketCB_Recieve, SocketCB_Disconnect, API_URL, 80);
        SocketSetArg(Socket, pack);
        return;
    }
    else if(g_bSteamWorks)
    {
        char sUrl[500];
        Format(sUrl, sizeof(sUrl), "http://%s%smaster.php", API_URL, API_PATH);
        Handle request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, sUrl);
        
        if(request == null)
        {
            LogError("Unkwown error ValidatePlayer() :: SteamWorks");
            return;
        }
        /*URLEncode(g_sCommunityName, sizeof(g_sCommunityName));
        URLEncode(sSteamID, 32);*/
        SteamWorks_SetHTTPRequestGetOrPostParameter(request, "STEAMID", sSteamID);
        SteamWorks_SetHTTPRequestGetOrPostParameter(request, "COMMUNITY", g_sCommunityName);
        SteamWorks_SetHTTPCallbacks(request, SteamWorks_OnDataReceive);
        SteamWorks_SetHTTPRequestContextValue(request, pack);
        bool sentrequest = SteamWorks_SendHTTPRequest(request);
        if(!sentrequest) 
        {
            LogError("ValidatePlayer() :: SteamWorks Error in sending request, cannot send request");
            CloseHandle(request);
            return;
        }
        SteamWorks_PrioritizeHTTPRequest(request);
        return;
    }
    // This should never happen, but redundancy is a good thing.
    else
        SetFailState("You must either have SteamWorks or Socket installed to run this plugin!");
}

/**
 * Kicks the player with the reason specified.
 * @note This will also temp IP Ban the player. This can be removed later if people don't like it.
 *
 * @param client        Client index.
 * @param sReasonRaw    Raw reason provided from web app.
 * @noreturn
 */
stock void GCC_KickPlayer(int client, char[] sReasonRaw)
{
    char sReason[64];
    Format(sReason, sizeof(sReason), "GCC Globally Banned! %s", sReasonRaw);
    LogAction(0, client, "Player is on the GCC Global Ban List! URL PROVIDED: %s", sReasonRaw);
    
    // 3 minute temp IP ban them to prevent reconnection spam. (This also kicks the client)
    BanClient(client, 3, BANFLAG_IP, sReason, sReason, "");
}


/**
 * URLEncoding for http requests.
 * @note Written by Peace-Maker?
 *
 * @param sString    String to format.
 * @param iMaxLen    Max length of the string.
 * @param sSafe      Additional characters to add to the safe check.
 * @param bFormat    Additional formatting.
 * @noreturn
 */
stock void URLEncode(char[] sString, int iMaxLen, char sSafe[] = "/", bool bFormat = false)
{
    char sAlwaysSafe[256];
    Format(sAlwaysSafe, sizeof(sAlwaysSafe), "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-%s", sSafe);
   
    // Need 2 '%' since sp's Format parses one as a parameter to replace
    // http://wiki.alliedmods.net/Format_Class_Functions_%28SourceMod_Scripting%29
    if(bFormat)
        ReplaceString(sString, iMaxLen, "%", "%%25");
    else
        ReplaceString(sString, iMaxLen, "%", "%25");
   
   
    char sChar[8], sReplaceChar[8];
    for(int i = 1; i < 256; i++)
    {
        if(i==37)   // Skip the '%' double replace ftw..
            continue;
       
        Format(sChar, sizeof(sChar), "%c", i);
        if(StrContains(sAlwaysSafe, sChar) == -1 && StrContains(sString, sChar) != -1)
        {
            if(bFormat)
                Format(sReplaceChar, sizeof(sReplaceChar), "%%%%%02X", i);
            else
                Format(sReplaceChar, sizeof(sReplaceChar), "%%%02X", i);
                
            ReplaceString(sString, iMaxLen, sChar, sReplaceChar);
        }
    }
}

/**
 * Checks available extensions that we can use.
 * @note Credit: https://forums.alliedmods.net/showpost.php?p=2256124&postcount=4
 *
 * @return           True if at least one extension detected, false otherwise.
 */
public void CheckAvailableExtensions()
{
    g_bSocket = (GetExtensionFileStatus("socket.ext")==1?true:false);
    g_bSteamWorks = (GetExtensionFileStatus("SteamWorks.ext")==1?true:false);
    if(!g_bSocket && !g_bSteamWorks)
        LogError("You must either have SteamWorks or Socket installed to run this plugin!");
}

/**
 * Gets the steam application ID from steam.inf
 * @note Can't remember who wrote this. Used it in one of HG's plugins. Think it was from AdminStealth.
 *
 * @noreturn
 */
stock void GrapAppId()
{
    char buffer[64];
    Handle file = OpenFile("./steam.inf", "r");
    
    do
    {
        if(!ReadFileLine(file, buffer, sizeof(buffer)))
            Format(g_sAppId, sizeof(g_sAppId), "ERROR");
        TrimString(buffer);
    }
    while(StrContains(buffer, "appID=", false) < 0);
    CloseHandle(file);
    ReplaceString(buffer, sizeof(buffer), "appID=", "", false);
    Format(g_sAppId, sizeof(g_sAppId), "%s", buffer);
}
