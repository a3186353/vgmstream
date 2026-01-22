local function script_dir()
    local src = debug.getinfo(1, 'S').source
    if type(src) ~= 'string' then
        return '.'
    end
    if src:sub(1, 1) == '@' then
        src = src:sub(2)
    end
    return src:match('^(.*)[/\\]') or '.'
end

local tools_dir = script_dir()
local repo_root = tools_dir:gsub('[/\\]tools$', '')

local input_dir = arg[1] or (repo_root .. [[\音频\sound]])
local output_dir = arg[2] or (input_dir .. [[\extracted_dll]])

local function prepend_cpath(dir)
    if not dir or dir == '' then
        return
    end
    if dir:sub(-1) == '\\' then
        dir = dir:sub(1, -2)
    end
    package.cpath = dir .. '\\?.dll;' .. package.cpath
end

prepend_cpath(repo_root .. [[\GGELUA\lib]])

local function mkdir_p(path)
    if not path or path == '' then
        return
    end
    os.execute('mkdir "' .. path .. '" >nul 2>nul')
end

local function file_exists(path)
    local f = io.open(path, 'rb')
    if f then
        f:close()
        return true
    end
    return false
end

local function sanitize_filename(name)
    if not name or name == '' then
        return ''
    end
    name = name:gsub('[<>:"/\\|%?%*]', '_')
    name = name:gsub('[%z%c]', '_')
    name = name:gsub('%s+$', '')
    name = name:gsub('^%s+', '')
    if #name > 200 then
        name = name:sub(1, 200)
    end
    return name
end

local function write_file(path, data)
    local f = assert(io.open(path, 'wb'))
    f:write(data)
    f:close()
end

local function split_dir_file(path)
    local i = path:match('^.*()\\')
    if not i then
        return '', path
    end
    return path:sub(1, i - 1), path:sub(i + 1)
end

local function stem(filename)
    return (filename:gsub('%.fsb$', ''):gsub('%.FSB$', ''))
end

local function collect_fsb_files(root)
    local list = {}
    local p = io.popen('dir /b /s "' .. root .. '\\*.fsb" 2>nul')
    if not p then
        return list
    end
    for line in p:lines() do
        if line and line ~= '' then
            list[#list + 1] = line
        end
    end
    p:close()
    table.sort(list)
    return list
end

local function relpath(full, root)
    local prefix = root
    if prefix:sub(-1) == '\\' then
        prefix = prefix:sub(1, -2)
    end
    if full:sub(1, #prefix):lower() ~= prefix:lower() then
        return full
    end
    local s = full:sub(#prefix + 1)
    if s:sub(1, 1) == '\\' then
        s = s:sub(2)
    end
    return s
end

mkdir_p(output_dir)

local function load_fsb_new()
    local ok1, mod1 = pcall(require, 'mygxy.fsb')
    if ok1 and type(mod1) == 'function' then
        return mod1
    end

    local ok2, mod2 = pcall(require, 'mygxy')
    if ok2 and type(mod2) == 'table' then
        if type(mod2.Fsb) == 'function' then
            return mod2.Fsb
        end
        if type(mod2.fsb) == 'function' then
            return mod2.fsb
        end
    end

    local so_path = package.searchpath('mygxy', package.cpath)
    if so_path then
        local loader = package.loadlib(so_path, 'luaopen_mygxy_fsb')
        if type(loader) == 'function' then
            local ok3, mod3 = pcall(loader)
            if ok3 and type(mod3) == 'function' then
                return mod3
            end
        end
    end

    return nil
end

local fsb_new = load_fsb_new()
if type(fsb_new) ~= 'function' then
    print('load fsb module failed')
    os.exit(2)
end

local fsb_files = collect_fsb_files(input_dir)
print(string.format('FSB 文件数: %d', #fsb_files))

local total_streams = 0
local ok_streams = 0
local fail_streams = 0
local fail_banks = 0

for fi = 1, #fsb_files do
    local fsb_path = fsb_files[fi]
    local rel = relpath(fsb_path, input_dir)
    local rel_dir, rel_file = split_dir_file(rel)
    local bank_stem = stem(rel_file)
    local out_bank_dir = output_dir
    if rel_dir ~= '' then
        out_bank_dir = out_bank_dir .. '\\' .. rel_dir
    end
    out_bank_dir = out_bank_dir .. '\\' .. bank_stem
    mkdir_p(out_bank_dir)

    local ok_open, ud, name2id, id2name = pcall(fsb_new, fsb_path)
    if not ok_open then
        fail_banks = fail_banks + 1
    else
        local n = 0
        if type(id2name) == 'table' then
            n = #id2name
        end

        if n == 0 then
            total_streams = total_streams + 1
            local ok_get, data, ext = pcall(function()
                return ud:Get(1)
            end)
            if ok_get and type(data) == 'string' and type(ext) == 'string' then
                local base = 'stream_001'
                local out_file = out_bank_dir .. '\\' .. base .. '.' .. ext
                local suffix = 1
                while file_exists(out_file) do
                    out_file = out_bank_dir .. '\\' .. base .. '_' .. suffix .. '.' .. ext
                    suffix = suffix + 1
                end
                write_file(out_file, data)
                ok_streams = ok_streams + 1
            else
                fail_streams = fail_streams + 1
            end
        else
            total_streams = total_streams + n
            for si = 1, n do
                local raw_name = id2name[si]
                local base = sanitize_filename(raw_name)
                if base == '' then
                    base = string.format('stream_%03d', si)
                end

                local ok_get, data, ext = pcall(function()
                    return ud:Get(si)
                end)

                if ok_get and type(data) == 'string' and type(ext) == 'string' then
                    local out_file = out_bank_dir .. '\\' .. base .. '.' .. ext
                    local suffix = 1
                    while file_exists(out_file) do
                        out_file = out_bank_dir .. '\\' .. base .. '_' .. suffix .. '.' .. ext
                        suffix = suffix + 1
                    end
                    local ok_write = pcall(write_file, out_file, data)
                    if ok_write then
                        ok_streams = ok_streams + 1
                    else
                        fail_streams = fail_streams + 1
                    end
                else
                    fail_streams = fail_streams + 1
                end
            end
        end
    end

    if fi % 50 == 0 or fi == #fsb_files then
        print(string.format('进度: %d/%d, 流: %d, 成功: %d, 失败: %d, 失败FSB: %d', fi, #fsb_files, total_streams, ok_streams, fail_streams, fail_banks))
    end
end

print(string.format('完成: FSB=%d, 流=%d, 成功=%d, 失败=%d, 失败FSB=%d', #fsb_files, total_streams, ok_streams, fail_streams, fail_banks))
