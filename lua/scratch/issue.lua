local paths = require("scratch.paths")

local M = {}

--- Only the head of a file is read: frontmatter plus the title line
local head_lines = 20

--- Fields every issue carries, with the values used when a file omits them
local defaults = {
    type = "task",
    priority = "normal",
    status = "open",
}

---@class scratch.Issue
---@field path string
---@field id string: file name without extension, also the creation time
---@field type string: bug|feature|task
---@field priority string: low|normal|high|critical
---@field status string: open|done
---@field title string

--- todo-comments keywords mapped onto issue types, so a comment in the code
--- can seed an issue. Keys follow that plugin's default keyword set.
local keyword_types = {
    FIX = "bug",
    FIXME = "bug",
    BUG = "bug",
    FIXIT = "bug",
    ISSUE = "bug",
    TODO = "task",
    HACK = "task",
    PERF = "task",
    OPTIM = "task",
    WARN = "task",
    XXX = "task",
    NOTE = "task",
    TEST = "task",
}

--- Read a todo comment: "// BUG: text" gives a type and a title.
--- The scoped form "// BUG(ref): text" is accepted too.
---@param line string
---@return table|nil
function M.from_comment(line)
    local keyword, text = line:match("(%u[%u%d_]*)%s*%b()%s*:%s*(.*)$")
    if keyword == nil then
        keyword, text = line:match("(%u[%u%d_]*)%s*:%s*(.*)$")
    end
    if keyword == nil or keyword_types[keyword] == nil then
        return nil
    end
    return { type = keyword_types[keyword], title = vim.trim(text) }
end

--- Directory holding the issues of a scope
---@param scope string: "local" or "global"
---@return string
function M.dir(scope)
    if scope == "global" then
        return paths.data_dir() .. "/issues"
    end
    return paths.root() .. "/.scratch/issues"
end

--- Whether a path is one of our issue files
---@param path string
---@return boolean
function M.is_issue(path)
    if path == "" then
        return false
    end
    local dir = vim.fn.fnamemodify(path, ":h")
    return dir == M.dir("local") or dir == M.dir("global")
end

--- Read an issue file. Everything below the title stays opaque to the store.
---@param path string
---@return scratch.Issue
function M.parse(path)
    local issue = vim.tbl_extend("force", {}, defaults)
    issue.path = path
    issue.id = vim.fn.fnamemodify(path, ":t:r")
    issue.title = issue.id

    local lines = vim.fn.readfile(path, "", head_lines)
    local body_start = 1

    if lines[1] == "---" then
        for i = 2, #lines do
            if lines[i] == "---" then
                body_start = i + 1
                break
            end
            local key, value = lines[i]:match("^(%w+):%s*(.-)%s*$")
            if key and defaults[key] then
                issue[key] = value
            end
        end
    end

    for i = body_start, #lines do
        local title = lines[i]:match("^#%s+(.+)$")
        if title then
            issue.title = title
            break
        end
    end

    return issue
end

--- Every issue of a scope, in whatever order the directory yields
---@param scope string
---@return scratch.Issue[]
function M.list(scope)
    local files = vim.fn.glob(M.dir(scope) .. "/*.md", false, true)
    local issues = {}
    for _, path in ipairs(files) do
        table.insert(issues, M.parse(path))
    end
    return issues
end

--- Write a new issue
---@param scope string
---@param fields table: type, priority, title, body
---@return string path
function M.create(scope, fields)
    local dir = M.dir(scope)
    if vim.fn.isdirectory(dir) == 0 then
        vim.fn.mkdir(dir, "p")
    end

    -- The file name is the creation time, so the store needs no counter and
    -- the directory sorts chronologically on its own
    local id = os.date("%Y-%m-%dT%H-%M-%S")
    local path = dir .. "/" .. id .. ".md"
    local suffix = 1
    while vim.fn.filereadable(path) == 1 do
        suffix = suffix + 1
        path = dir .. "/" .. id .. "-" .. suffix .. ".md"
    end

    local lines = {
        "---",
        "type: " .. (fields.type or defaults.type),
        "priority: " .. (fields.priority or defaults.priority),
        "status: " .. defaults.status,
        "---",
        "",
        "# " .. (fields.title or ""),
        "",
    }
    vim.list_extend(lines, fields.body or {})

    vim.fn.writefile(lines, path)
    return path
end

return M
