--[[
PLEASE NOTE: This adapter is not supported by CodeCompanion.nvim.
It is simply provided as an example for how you can connect an OpenAI compatible endpoint
to CodeCompanion via an adapter. Send any questions or queries to the discussions.
--]]

local Curl = require("plenary.curl")
local adapter_utils = require("codecompanion.adapters.utils")
local config = require("codecompanion.config")
local log = require("codecompanion.utils.log")
local openai = require("codecompanion.adapters.http.openai")
local uv = vim.uv or vim.loop

local _cache_expires
local _cached_models

local _cached_token = nil
local _token_expires = nil

local _chat_id = nil

-- token 缓存文件（同一用户同一台机器不同 nvim 实例可共享）
local function token_cache_file()
    local dir = vim.fn.stdpath("state") .. "/codecompanion"
    vim.fn.mkdir(dir, "p")
    return dir .. "/tplink_auth_token.json"
end

local function read_token_from_file()
    local path = token_cache_file()
    local fd = uv.fs_open(path, "r", 384) -- 0600
    if not fd then
        return nil
    end

    local stat = uv.fs_fstat(fd)
    if not stat or stat.size == 0 then
        uv.fs_close(fd)
        return nil
    end

    local data = uv.fs_read(fd, stat.size, 0)
    uv.fs_close(fd)
    if not data or data == "" then
        return nil
    end

    local ok, obj = pcall(vim.json.decode, data)
    if not ok or type(obj) ~= "table" then
        return nil
    end

    if not obj.token or not obj.expires or obj.expires <= os.time() then
        return nil
    end

    return obj.token, obj.expires
end

local function write_token_to_file(token, expires)
    local path = token_cache_file()
    local payload = vim.json.encode({ token = token, expires = expires })

    -- 0600：仅当前用户可读写
    local fd = uv.fs_open(path, "w", 384)
    if not fd then
        return false
    end

    uv.fs_write(fd, payload, 0)
    uv.fs_close(fd)
    return true
end
local function get_token(self)
    -- 1) 先用内存缓存
    if _cached_token and _token_expires and _token_expires > os.time() then
        return _cached_token
    end

    -- 2) 再尝试从临时/状态文件读取（跨实例共享）
    do
        local token, expires = read_token_from_file()
        if token and expires then
            _cached_token = token
            _token_expires = expires
            return _cached_token
        end
    end

    -- 3) 文件也没有/过期，则走网络获取
    local adapter = require("codecompanion.adapters").resolve(self)
    if not adapter then
        log:error("Could not resolve adapter")
        return nil
    end
    adapter_utils.get_env_vars(adapter, { timeout = config.adapters.opts.cmd_timeout })
    log:trace("adapter: %s", vim.json.encode(adapter.env_replaced))

    local url = adapter.env_replaced.url .. adapter.env_replaced.auth_url
    local username = adapter.env_replaced.username
    local password = adapter.env_replaced.password
    log:trace("url: %s", url and url or "")
    log:trace("username: %s", username and username or "")
    log:trace("password: %s", password and password or "")

    local ok, request, response, json
    request = {
        sync = true,
        headers = {
            ["Content-Type"] = "application/json",
        },
        body = vim.json.encode({
            username = username,
            password = password,
        }),
    }
    log:trace("url: %s  request: %s", url, vim.json.encode(request))
    ok, response = pcall(function()
        return Curl.post(url, request)
    end)

    if response ~= nil then
        log:trace("response: %s", response)
    end

    if not ok or response == nil or response.status ~= 200 then
        log:error("Failed to get token: %d %s", response.status, response.body)
        return nil
    end

    ok, json = pcall(vim.json.decode, response.body)

    if not ok then
        log:error("Failed to parse token response")
        return nil
    end

    if json.code ~= 0 then
        log:error("Token api error: %s", json.message)
        return nil
    end

    _cached_token = json.data.accessToken

    -- 缓存1小时
    _token_expires = os.time() + 3600

    -- 4) 写入文件，供下一个实例复用
    write_token_to_file(_cached_token, _token_expires)

    return _cached_token
end

local function get_chatid(self)
    if _chat_id then
        return _chat_id
    end

    local token = get_token()
    if not token then
        return nil
    end

    local adapter = require("codecompanion.adapters").resolve(self)
    if not adapter then
        log:error("Could not resolve adapter")
        return nil
    end
    adapter_utils.get_env_vars(adapter, { timeout = config.adapters.opts.cmd_timeout })
    local url = adapter.env_replaced.url .. adapter.env_replaced.chatid_url
    log:trace("url: %s", url and url or "")

    local ok, request, response, json

    request = {
        sync = true,
        headers = {
            ["Content-Type"] = "application/json",
            ["Authorization"] = token,
        },
    }
    log:trace("url: %s  request: %s", url, vim.json.encode(request))

    ok, response = pcall(function()
        return Curl.get(url, request)
    end)
    if response ~= nil then
        log:trace("response: %s", response)
    end

    if not ok or response == nil or response.status ~= 200 then
        log:error("Failed to get chatid: %d %s", response.status, response.body)
        return nil
    end

    ok, json = pcall(vim.json.decode, response.body)

    if not ok then
        log:error("Failed to parse chatid response")
        return nil
    end

    if json.code ~= 0 then
        log:error("chatid api error: %s", json.message)
        return nil
    end

    _chat_id = json.data

    return _chat_id
end

local function find_history_by_chatid()
    if not _chat_id then
        return nil
    end
    local token = get_token()
    if not token then
        return nil
    end

    local adapter = require("codecompanion.adapters").resolve(self)
    if not adapter then
        log:error("Could not resolve adapter")
        return nil
    end
    adapter_utils.get_env_vars(adapter, { timeout = config.adapters.opts.cmd_timeout })
    local url = adapter.env_replaced.url .. adapter.env_replaced.history_url
    log:trace("url: %s", url and url or "")

    local ok, request, response, json

    request = {
        sync = true,
        headers = {
            ["Accept"] = "application/json",
            ["Content-Type"] = "application/json",
            ["Authorization"] = token,
        },
        body = vim.json.encode(_chat_id),
    }
    log:trace("url: %s  request: %s", url, vim.json.encode(request))

    ok, response = pcall(function()
        return Curl.post(url, request)
    end)

    if response ~= nil then
        log:trace("response: %s", response)
    end

    if not ok then
        log:error("Failed to get history chat: %s", response)
        return nil
    end

    ok, json = pcall(vim.json.decode, response.body)

    if not ok then
        log:error("Failed to parse history chat response")
        return nil
    end

    if json.code ~= 0 then
        log:error("history chat api error")
        return nil
    end

    -- if json.code == 0 then
    --     local infos = json.data.chatListInfos
    --     for _, item in ipairs(infos) do
    --         print("Q:", item.question)
    --         print("A:", item.answer)
    --         print("Time:", item.timeStamp)
    --     end
    -- end

    return json.data.chatListInfos
end

---Return the cached models
---@params opts? table
local function models(opts)
    if opts and opts.last then
        return _cached_models[1]
    end
    return _cached_models
end

---@class CodeCompanion.HTTPAdapter.OpenAICompatible: CodeCompanion.HTTPAdapter
return {
    name = "tplink",
    formatted_name = "TP-Link",
    roles = {
        llm = "assistant",
        user = "user",
    },
    opts = {
        stream = true,
        tools = false,
        vision = false,
    },
    features = {
        text = true,
        tokens = true,
    },
    url = "${url}${chat_url}",
    env = {
        username = "USERNAME",
        password = "PASSWORD",
        url = "https://aichat.tp-link.com",
        chat_url = "/api/chat/chat",
        chatid_url = "/api/chat/generateNewChatid",
        history_url = "/api/chat/findHistoryByChatid",
        auth_url = "/api/auth/login",
        models_endpoint = "/api/chat/getMyModels",
    },
    headers = {
        -- Authorization = "${api_key}",
        ["Authorization"] = function(self)
            return get_token(self)
            -- return "Bearer 0aa84260-b827-4db8-a738-ae227b8594ec"
        end,
        ["Accept"] = "text/event-stream",
        ["Content-Type"] = "text/event-stream",
    },
    handlers = {
        ---@param self CodeCompanion.HTTPAdapter
        ---@return boolean
        setup = function(self)
            if self.opts and self.opts.stream then
                self.parameters.stream = true
                self.parameters.stream_options = { include_usage = true }
            end
            return true
        end,

        tokens = function(self, data)
            return openai.handlers.tokens(self, data)
        end,
        form_parameters = function(self, params, messages)
            return openai.handlers.form_parameters(self, params, messages)
        end,
        form_messages = function(self, messages)
            local question = ""
            local history = {}
            local chatid = get_chatid()

            log:trace(chatid)
            local chatListInfos = find_history_by_chatid()

            if chatListInfos then
                for _, msg in ipairs(chatListInfos) do
                    local temp = vim.deepcopy(msg)
                    table.insert(history, temp)
                end
            end

            for _, msg in ipairs(messages) do
                if msg.role == "user" then
                    question = msg.content
                end
            end
            local payload = {
                model = "DeepSeek-V4-Flash",
                history = history,
                question = question,
                chatid = chatid,
                category = "",
            }

            return payload
        end,

        form_tools = function(self, tools)
            return openai.handlers.form_tools(self, tools)
        end,
        -- chat_output = function(self, data, tools)
        --     return openai.handlers.chat_output(self, data, tools)
        -- end,
        chat_output = function(self, data, tools)
            if not data or data == "" then
                return {
                    status = "error",
                    output = {
                        content = "返回内容为空",
                    },
                }
            end

            local body

            if type(data) == "table" then
                body = data.body or ""
            else
                body = data
            end

            body = body:gsub("^data:", ""):gsub("\n$", "")

            local ok, obj = pcall(vim.json.decode, body)

            if not ok then
                return {
                    status = "error",
                    output = {
                        content = "返回内容格式错误",
                    },
                }
            end

            local ret = {}
            -- 流结束
            if #obj.data <= 0 then
                ret = {
                    status = "success",
                    output = {
                        role = "assistant",
                        content = "",
                    },
                    done = true,
                }
            elseif obj.code ~= 0 then
                ret = {
                    status = "error",
                    output = {
                        content = obj.data or obj.message,
                    },
                }
            elseif string.match(obj.data, "您的账号未认证或账号无权限！") then
                ret = {
                    status = "success",
                    output = {
                        role = "assistant",
                        content = "认证过期，已刷新Token，请再次尝试",
                    },
                    done = true,
                }
                _cached_token = nil
                _token_expires = nil
                local path = token_cache_file()
                local file = io.open(path, "r")
                if file then
                    file:close()
                    local ok, err = os.remove(path)
                end

                get_token()
            else
                ret = {
                    status = "success",
                    output = {
                        role = "assistant",
                        content = obj.data or "",
                    },
                }
            end
            return ret
        end,

        inline_output = function(self, data, context)
            return openai.handlers.inline_output(self, data, context)
        end,
        tools = {
            format_tool_calls = function(self, tools)
                return openai.handlers.tools.format_tool_calls(self, tools)
            end,
            output_response = function(self, tool_call, output)
                return openai.handlers.tools.output_response(self, tool_call, output)
            end,
        },
        on_exit = function(self, data)
            return openai.handlers.on_exit(self, data)
        end,
    },
    schema = {
        ---@type CodeCompanion.Schema
        model = {
            order = 1,
            mapping = "parameters",
            type = "enum",
            desc = "ID of the model to use. See the model endpoint compatibility table for details on which models work with the Chat API.",
            default = "DeepSeek-V4-Flash",
            choices = {
                ["DeepSeek-V4-Pro"] = {
                    formatted_name = "DeepSeek-V4-Pro",
                    meta = { context_window = 1050000 },
                    opts = {
                        can_form_structured_outputs = true,
                        can_manage_context = true,
                        can_use_tools = true,
                        can_reason = false,
                        has_vision = true,
                    },
                },
                ["DeepSeek-V4-Flash"] = {
                    formatted_name = "DeepSeek-V4-Flash",
                    meta = { context_window = 1050000 },
                    opts = {
                        can_form_structured_outputs = true,
                        can_manage_context = true,
                        can_use_tools = true,
                        can_reason = true,
                        has_vision = true,
                    },
                },
                ["GPT-5.2"] = {
                    formatted_name = "GPT-5.2",
                    meta = { context_window = 1050000 },
                    opts = {
                        can_form_structured_outputs = true,
                        can_manage_context = true,
                        can_use_tools = true,
                        can_reason = true,
                        has_vision = true,
                    },
                },
            },
        },
    },
}
