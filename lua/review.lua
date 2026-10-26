-- GitLab-style review threads for local (AI-generated) changes.
--
-- Threads live in <repo>/.review/comments.md, a plain markdown file that both
-- this module and Claude (the /review-comments skill) read and edit. Comments
-- are added from diffview or any file buffer and shown as virtual lines under
-- the commented range. File format:
--
--   ## [open] #3 src/foo.py:42-48 (new @ worktree)
--
--   ```python
--   <snippet of the commented lines>
--   ```
--
--   **me:** why does this swallow the exception?
--
--   **claude:** it shouldn't -- fixed in a1b2c3d, it now re-raises.
local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("review")

local FILE = ".review/comments.md"
local HEADER = {
	"# Code review",
	"",
	"<!-- Managed by nvim (lua/review.lua) and Claude (/review-comments).",
	"     Thread heading: ## [open|resolved] #<id> <path>:<start>-<end> (<old|new> @ <rev>)",
	"     Messages start with **me:** or **claude:**. Not meant to be committed. -->",
}

M.show_resolved = false

-- root -> { mtime, lines, threads }
local cache = {}
-- root -> uv fs_event handle
local watchers = {}
-- bufnr -> { root, items = { { thread, l1, l2 } } }, what is currently drawn
local drawn = {}

-- Parsing -------------------------------------------------------------------

local function parse_heading(line)
	local status, id, path, l1, l2, side, rev =
		line:match("^## %[(%a+)%] #(%d+) (.+):(%d+)%-(%d+) %((%a+) @ ([^)]*)%)%s*$")
	if not status then
		status, id, path, l1, side, rev = line:match("^## %[(%a+)%] #(%d+) (.+):(%d+) %((%a+) @ ([^)]*)%)%s*$")
		l2 = l1
	end
	if not status then
		return nil
	end
	return {
		status = status,
		id = tonumber(id),
		path = path,
		l1 = tonumber(l1),
		l2 = tonumber(l2),
		side = side,
		rev = rev,
	}
end

local function parse(lines)
	local threads = {}
	local cur, fence
	for i, line in ipairs(lines) do
		local t = not fence and parse_heading(line)
		if t then
			t.start, t.stop, t.snippet, t.messages = i, i, {}, {}
			cur = t
			table.insert(threads, t)
		elseif not fence and line:match("^#+ ") then
			cur = nil
		elseif cur then
			if line:match("%S") then
				cur.stop = i
			end
			local author, text
			if not fence then
				author, text = line:match("^%*%*([%w_-]+):%*%*%s?(.*)$")
			end
			-- Track code fences so "**x:**" or "# ..." inside code isn't misread.
			local ticks = line:match("^%s*(```+)")
			local was_fenced = fence
			if fence then
				if ticks and #ticks >= #fence and line:match("^%s*`+%s*$") then
					fence = nil
				end
			elseif ticks then
				fence = ticks
			end

			if author then
				table.insert(cur.messages, { author = author, lines = { text } })
			elseif #cur.messages > 0 then
				table.insert(cur.messages[#cur.messages].lines, line)
			elseif was_fenced and fence then
				-- The first fenced block before any message is the snippet.
				table.insert(cur.snippet, line)
			end
		end
	end
	for _, t in ipairs(threads) do
		for _, m in ipairs(t.messages) do
			while #m.lines > 1 and not m.lines[#m.lines]:match("%S") do
				table.remove(m.lines)
			end
		end
	end
	return threads
end

-- File IO -------------------------------------------------------------------

local function path_of(root)
	return root .. "/" .. FILE
end

local function refresh_soon()
	-- Coalesce bursts of fs events (editors often write in several steps).
	if M._pending then
		return
	end
	M._pending = true
	vim.defer_fn(function()
		M._pending = false
		M.refresh()
	end, 100)
end

local function watch(root)
	if watchers[root] then
		return
	end
	local dir = root .. "/.review"
	if not vim.uv.fs_stat(dir) then
		return
	end
	local handle = vim.uv.new_fs_event()
	if not handle then
		return
	end
	handle:start(dir, {}, function()
		vim.schedule(refresh_soon)
	end)
	watchers[root] = handle
end

local function load(root)
	local file = path_of(root)
	local stat = vim.uv.fs_stat(file)
	if not stat then
		cache[root] = nil
		return { lines = {}, threads = {} }
	end
	watch(root)
	local mtime = stat.mtime.sec .. "." .. stat.mtime.nsec .. ":" .. stat.size
	local c = cache[root]
	if c and c.mtime == mtime then
		return c
	end
	local lines = vim.fn.readfile(file)
	c = { mtime = mtime, lines = lines, threads = parse(lines) }
	cache[root] = c
	return c
end

local function write(root, lines)
	local file = path_of(root)
	local buf = vim.fn.bufnr(file)
	if buf ~= -1 and vim.bo[buf].modified then
		vim.notify("review: " .. FILE .. " has unsaved changes in a buffer, save it first", vim.log.levels.WARN)
		return false
	end
	vim.fn.mkdir(root .. "/.review", "p")
	-- Keep the whole directory out of git without touching the repo's .gitignore.
	if not vim.uv.fs_stat(root .. "/.review/.gitignore") then
		vim.fn.writefile({ "*" }, root .. "/.review/.gitignore")
	end
	vim.fn.writefile(lines, file)
	cache[root] = nil
	if buf ~= -1 then
		vim.cmd.checktime(buf)
	end
	watch(root)
	M.refresh()
	return true
end

-- Locating buffers and threads ----------------------------------------------

local function rev_label(rev)
	if not rev then
		return "?"
	end
	local RevType = require("diffview.vcs.rev").RevType
	if rev.type == RevType.LOCAL then
		return "worktree"
	elseif rev.type == RevType.STAGE then
		return "index"
	elseif rev.type == RevType.COMMIT then
		return rev:abbrev(10)
	end
	return "?"
end

---What a window shows, in review terms.
---@return integer? buf, string? root, table? info { path, side, rev }
local function win_info(win)
	local buf = api.nvim_win_get_buf(win)
	-- Only consult diffview if something already loaded it.
	local lib = package.loaded["diffview.lib"]
	local view = lib and lib.get_current_view()
	if view and view.cur_layout and api.nvim_win_get_tabpage(win) == view.tabpage then
		for _, w in ipairs(view.cur_layout.windows) do
			if w.id == win and w.file and w.file.path then
				return buf,
					view.adapter.ctx.toplevel,
					{
						path = w.file.path,
						-- diff2: a = old, b = new. diff3/4 (merges): b is the local side.
						side = w.file.symbol == "b" and "new" or "old",
						rev = rev_label(w.file.rev),
					}
			end
		end
	end
	local name = api.nvim_buf_get_name(buf)
	if vim.bo[buf].buftype ~= "" or name == "" or name:match("^%a+://") then
		return buf
	end
	local root = vim.fs.root(name, ".git")
	local rel = root and vim.fs.relpath(root, name)
	if not rel or rel == FILE then
		return buf
	end
	return buf, root, { path = rel, side = "new", rev = "worktree" }
end

---Find where a thread sits in the buffer now: line numbers drift as code is
---edited, so re-anchor on the first non-blank snippet line near the old spot.
local function locate(lines, t)
	local n = #lines
	local function clamp(l)
		return math.max(1, math.min(l, math.max(n, 1)))
	end
	local idx, anchor
	for i, s in ipairs(t.snippet) do
		if s:match("%S") then
			idx, anchor = i, vim.trim(s)
			break
		end
	end
	if anchor then
		local want = t.l1 + idx - 1
		for d = 0, 300 do
			for _, l in ipairs(d == 0 and { want } or { want - d, want + d }) do
				if lines[l] and vim.trim(lines[l]) == anchor then
					return clamp(t.l1 + l - want), clamp(t.l2 + l - want)
				end
			end
		end
	end
	return clamp(t.l1), clamp(t.l2)
end

-- Rendering -----------------------------------------------------------------

local function state(t)
	if t.status == "resolved" then
		return "resolved", "ReviewResolved"
	end
	local last = t.messages[#t.messages]
	if last and last.author ~= "me" then
		return "Claude replied", "ReviewReplied"
	end
	return "waiting for Claude", "ReviewOpen"
end

local function wrap(text, width)
	if #text <= width then
		return { text }
	end
	local out, line = {}, ""
	for word in text:gmatch("%S+") do
		if line ~= "" and #line + 1 + #word > width then
			table.insert(out, line)
			line = word
		else
			line = line == "" and word or line .. " " .. word
		end
	end
	table.insert(out, line)
	return out
end

local MAX_LINES = 14

local function virt_lines(t, width, indent)
	local label, hl = state(t)
	local pad = string.rep(" ", indent)
	local out = { { { pad .. "┌ ", hl }, { ("#%d %s"):format(t.id, label), hl } } }
	local body = {}
	for _, m in ipairs(t.messages) do
		local author_hl = m.author == "me" and "ReviewAuthorMe" or "ReviewAuthorClaude"
		local prefix = m.author .. ": "
		for i, l in ipairs(m.lines) do
			for j, w in ipairs(wrap(l, width - #prefix)) do
				local head = (i == 1 and j == 1) and prefix or string.rep(" ", #prefix)
				table.insert(body, { { pad .. "│ ", hl }, { head, author_hl }, { w, "ReviewBody" } })
			end
		end
	end
	if #body > MAX_LINES then
		local more = #body - MAX_LINES + 1
		body = vim.list_slice(body, 1, MAX_LINES - 1)
		table.insert(body, { { pad .. "│ ", hl }, { ("… %d more lines, <leader>rv to view"):format(more), "Comment" } })
	end
	vim.list_extend(out, body)
	table.insert(out, { { pad .. "└", hl } })
	return out
end

local function render(win)
	local buf, root, info = win_info(win)
	api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	drawn[buf] = nil
	if not root then
		return
	end
	local threads = load(root).threads
	local items = {}
	local lines
	for _, t in ipairs(threads) do
		if t.path == info.path and t.side == info.side and (M.show_resolved or t.status ~= "resolved") then
			lines = lines or api.nvim_buf_get_lines(buf, 0, -1, false)
			local l1, l2 = locate(lines, t)
			table.insert(items, { thread = t, l1 = l1, l2 = l2 })
			local _, hl = state(t)
			for l = l1, math.min(l2, l1 + 200) do
				api.nvim_buf_set_extmark(buf, ns, l - 1, 0, { sign_text = "▍", sign_hl_group = hl, priority = 20 })
			end
			local indent = (lines[l1] or ""):match("^%s*"):gsub("\t", string.rep(" ", vim.bo[buf].tabstop))
			local width = math.max(40, api.nvim_win_get_width(win) - #indent - 12)
			api.nvim_buf_set_extmark(buf, ns, l2 - 1, 0, { virt_lines = virt_lines(t, width, #indent) })
		end
	end
	drawn[buf] = { root = root, items = items }
end

function M.refresh()
	for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
		if api.nvim_win_get_config(win).relative == "" then
			pcall(render, win)
		end
	end
end

-- Interaction ---------------------------------------------------------------

local prompt_id = 0

---Open a small markdown float to write a message; :w or <C-s> submits.
local function prompt(title, on_submit)
	prompt_id = prompt_id + 1
	local buf = api.nvim_create_buf(false, true)
	api.nvim_buf_set_name(buf, ("review://%d/%s"):format(prompt_id, title))
	vim.bo[buf].buftype = "acwrite"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "markdown"
	local width = math.min(90, math.floor(vim.o.columns * 0.7))
	local height = 10
	local win = api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2) - 1,
		col = math.floor((vim.o.columns - width) / 2),
		border = "rounded",
		title = " " .. title .. " ",
		title_pos = "center",
		footer = " :w / <C-s> submit · q cancel ",
		footer_pos = "center",
	})
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true

	local function close()
		if api.nvim_win_is_valid(win) then
			api.nvim_win_close(win, true)
		end
		if api.nvim_buf_is_valid(buf) then
			api.nvim_buf_delete(buf, { force = true })
		end
	end
	local submitted = false
	local function submit()
		if submitted then
			return
		end
		submitted = true
		local text = api.nvim_buf_get_lines(buf, 0, -1, false)
		while #text > 0 and not text[#text]:match("%S") do
			table.remove(text)
		end
		while #text > 0 and not text[1]:match("%S") do
			table.remove(text, 1)
		end
		vim.bo[buf].modified = false
		vim.cmd.stopinsert()
		-- Deferred so ":wq" can finish closing the float itself first.
		vim.schedule(function()
			close()
			if #text > 0 then
				on_submit(text)
			end
		end)
	end
	api.nvim_create_autocmd("BufWriteCmd", { buffer = buf, callback = submit })
	vim.keymap.set({ "n", "i" }, "<C-s>", submit, { buffer = buf })
	vim.keymap.set("n", "q", close, { buffer = buf })
	vim.keymap.set("n", "<Esc>", close, { buffer = buf })
	vim.cmd.startinsert()
end

local function message(author, text)
	local out = { "", "**" .. author .. ":** " .. text[1] }
	vim.list_extend(out, text, 2)
	return out
end

local function current_root()
	local _, root = win_info(api.nvim_get_current_win())
	if root then
		return root
	end
	return vim.fs.root(0, ".git") or vim.fs.root(vim.fn.getcwd(), ".git")
end

---Call fn(thread, root) for the thread under the cursor, or let the user pick.
local function with_thread(fn, opts)
	opts = opts or {}
	local buf = api.nvim_get_current_buf()
	local lnum = api.nvim_win_get_cursor(0)[1]

	-- Inside comments.md itself: the thread whose block contains the cursor.
	local name = api.nvim_buf_get_name(buf)
	if name:sub(-#FILE) == FILE then
		local root = name:sub(1, -#FILE - 2)
		for _, t in ipairs(parse(api.nvim_buf_get_lines(buf, 0, -1, false))) do
			if lnum >= t.start and lnum <= t.stop then
				return fn(t, root)
			end
		end
	end

	local d = drawn[buf]
	if d then
		local best, dist
		for _, item in ipairs(d.items) do
			local away = lnum < item.l1 and item.l1 - lnum or lnum > item.l2 and lnum - item.l2 or 0
			if away <= 2 and (not dist or away < dist) then
				best, dist = item, away
			end
		end
		if best then
			return fn(best.thread, d.root)
		end
	end

	local root = d and d.root or current_root()
	if not root then
		return vim.notify("review: not in a git repository", vim.log.levels.WARN)
	end
	local choices = vim.tbl_filter(function(t)
		return opts.include_resolved or t.status ~= "resolved"
	end, load(root).threads)
	if #choices == 0 then
		return vim.notify("review: no threads", vim.log.levels.INFO)
	end
	vim.ui.select(choices, {
		prompt = "Review thread",
		format_item = function(t)
			local first = t.messages[1] and t.messages[1].lines[1] or ""
			return ("#%d %s:%d  %s"):format(t.id, t.path, t.l1, first)
		end,
	}, function(t)
		if t then
			fn(t, root)
		end
	end)
end

---Re-read the file and find a thread by id (lines may have moved since parse).
local function fresh(root, id)
	local data = load(root)
	for _, t in ipairs(data.threads) do
		if t.id == id then
			return t, vim.deepcopy(data.lines)
		end
	end
end

local function set_status(lines, t, status)
	lines[t.start] = lines[t.start]:gsub("^## %[%a+%]", "## [" .. status .. "]", 1)
end

function M.comment()
	local l1, l2
	local mode = vim.fn.mode()
	if mode == "v" or mode == "V" or mode == "\22" then
		l1, l2 = vim.fn.line("v"), vim.fn.line(".")
		if l1 > l2 then
			l1, l2 = l2, l1
		end
		api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
	else
		l1 = vim.fn.line(".")
		l2 = l1
	end
	M.comment_range(l1, l2)
end

function M.comment_range(l1, l2)
	local buf, root, info = win_info(api.nvim_get_current_win())
	if not root then
		return vim.notify("review: not a file in a git repository", vim.log.levels.WARN)
	end
	local snippet = api.nvim_buf_get_lines(buf, l1 - 1, l2, false)
	local ft = vim.bo[buf].filetype
	prompt(("Comment on %s:%d-%d"):format(info.path, l1, l2), function(text)
		local data = load(root)
		local lines = #data.lines > 0 and vim.deepcopy(data.lines) or vim.deepcopy(HEADER)
		local id = 0
		for _, t in ipairs(data.threads) do
			id = math.max(id, t.id)
		end
		-- A fence longer than any backtick run in the snippet keeps it intact.
		local fence = "```"
		for _, s in ipairs(snippet) do
			for run in s:gmatch("`+") do
				if #run >= #fence then
					fence = string.rep("`", #run + 1)
				end
			end
		end
		vim.list_extend(lines, {
			"",
			("## [open] #%d %s:%d-%d (%s @ %s)"):format(id + 1, info.path, l1, l2, info.side, info.rev),
			"",
			fence .. ft,
		})
		vim.list_extend(lines, snippet)
		table.insert(lines, fence)
		vim.list_extend(lines, message("me", text))
		write(root, lines)
	end)
end

function M.reply()
	with_thread(function(t, root)
		prompt(("Reply to #%d"):format(t.id), function(text)
			local cur, lines = fresh(root, t.id)
			if not cur then
				return vim.notify("review: thread #" .. t.id .. " is gone", vim.log.levels.WARN)
			end
			for i, l in ipairs(message("me", text)) do
				table.insert(lines, cur.stop + i, l)
			end
			set_status(lines, cur, "open")
			write(root, lines)
		end)
	end, { include_resolved = true })
end

function M.toggle_resolved()
	with_thread(function(t, root)
		local cur, lines = fresh(root, t.id)
		if not cur then
			return
		end
		local status = cur.status == "resolved" and "open" or "resolved"
		set_status(lines, cur, status)
		if write(root, lines) then
			vim.notify(("review: #%d %s"):format(t.id, status == "open" and "reopened" or "resolved"))
		end
	end, { include_resolved = true })
end

function M.view()
	with_thread(function(t, root)
		local cur, lines = fresh(root, t.id)
		if not cur then
			return
		end
		local block = vim.list_slice(lines, cur.start, cur.stop)
		local buf = api.nvim_create_buf(false, true)
		api.nvim_buf_set_lines(buf, 0, -1, false, block)
		vim.bo[buf].filetype = "markdown"
		vim.bo[buf].modifiable = false
		vim.bo[buf].bufhidden = "wipe"
		local width = math.min(100, math.floor(vim.o.columns * 0.8))
		local height = math.min(#block + 1, math.floor(vim.o.lines * 0.7))
		local win = api.nvim_open_win(buf, true, {
			relative = "editor",
			width = width,
			height = height,
			row = math.floor((vim.o.lines - height) / 2) - 1,
			col = math.floor((vim.o.columns - width) / 2),
			border = "rounded",
			title = (" #%d "):format(t.id),
			title_pos = "center",
			footer = " r reply · x resolve/reopen · q close ",
			footer_pos = "center",
		})
		vim.wo[win].wrap = true
		vim.wo[win].linebreak = true
		local function close()
			if api.nvim_win_is_valid(win) then
				api.nvim_win_close(win, true)
			end
		end
		local function then_(fn)
			return function()
				close()
				-- The float is gone, so the cursor is back on the thread.
				fn()
			end
		end
		vim.keymap.set("n", "q", close, { buffer = buf })
		vim.keymap.set("n", "<Esc>", close, { buffer = buf })
		vim.keymap.set("n", "r", then_(M.reply), { buffer = buf })
		vim.keymap.set("n", "x", then_(M.toggle_resolved), { buffer = buf })
	end, { include_resolved = true })
end

function M.list(include_resolved)
	local root = current_root()
	if not root then
		return vim.notify("review: not in a git repository", vim.log.levels.WARN)
	end
	local items = {}
	for _, t in ipairs(load(root).threads) do
		if include_resolved or t.status ~= "resolved" then
			local label = state(t)
			local last = t.messages[#t.messages]
			items[#items + 1] = {
				filename = root .. "/" .. t.path,
				lnum = t.l1,
				end_lnum = t.l2,
				text = ("#%d [%s] %s%s"):format(
					t.id,
					label,
					t.side == "old" and "(old side) " or "",
					last and (last.author .. ": " .. last.lines[1]) or ""
				),
			}
		end
	end
	if #items == 0 then
		return vim.notify("review: no open threads", vim.log.levels.INFO)
	end
	vim.fn.setqflist({}, " ", { title = "Review threads", items = items })
	vim.cmd("botright copen")
end

function M.open()
	local root = current_root()
	if not root then
		return vim.notify("review: not in a git repository", vim.log.levels.WARN)
	end
	if not vim.uv.fs_stat(path_of(root)) then
		return vim.notify("review: no comments yet", vim.log.levels.INFO)
	end
	vim.cmd("botright split " .. vim.fn.fnameescape(path_of(root)))
end

---Drop resolved threads (or every thread with all = true).
function M.clear(all)
	local root = current_root()
	if not root then
		return
	end
	local data = load(root)
	local lines = vim.deepcopy(data.lines)
	local removed = 0
	for i = #data.threads, 1, -1 do
		local t = data.threads[i]
		if all or t.status == "resolved" then
			local next_start = data.threads[i + 1] and data.threads[i + 1].start or #lines + 1
			-- Remove the block plus the blank lines that follow it.
			local stop = t.stop
			while stop + 1 < next_start and not (lines[stop + 1] or "x"):match("%S") do
				stop = stop + 1
			end
			for _ = t.start, stop do
				table.remove(lines, t.start)
			end
			removed = removed + 1
		end
	end
	if removed > 0 and write(root, lines) then
		vim.notify(("review: removed %d thread(s)"):format(removed))
	end
end

function M.toggle_show_resolved()
	M.show_resolved = not M.show_resolved
	M.refresh()
	vim.notify("review: " .. (M.show_resolved and "showing" or "hiding") .. " resolved threads")
end

---Ask Claude to work through the open threads.
function M.send_to_claude()
	local cmd = "/review-comments"
	local term = package.loaded["claudecode"] and require("claudecode.terminal")
	if term and term.get_active_terminal_bufnr() and term.send_to_terminal(cmd, { focus = true }) then
		return
	end
	vim.fn.setreg("+", cmd)
	vim.notify("review: no Claude terminal in nvim, copied " .. cmd .. " to the clipboard")
end

function M.setup()
	local function hl(name, link)
		api.nvim_set_hl(0, name, { link = link, default = true })
	end
	hl("ReviewOpen", "DiagnosticInfo")
	hl("ReviewReplied", "DiagnosticWarn")
	hl("ReviewResolved", "Comment")
	hl("ReviewAuthorMe", "Identifier")
	hl("ReviewAuthorClaude", "Special")
	hl("ReviewBody", "Normal")

	local group = api.nvim_create_augroup("review", { clear = true })
	api.nvim_create_autocmd({ "BufWinEnter", "TabEnter", "FocusGained", "VimResized" }, {
		group = group,
		callback = refresh_soon,
	})
	api.nvim_create_autocmd("User", {
		group = group,
		pattern = { "DiffviewDiffBufWinEnter", "DiffviewViewEnter", "DiffviewViewPostLayout" },
		callback = refresh_soon,
	})
	-- Hand edits to comments.md inside nvim show up immediately too.
	api.nvim_create_autocmd("BufWritePost", {
		group = group,
		pattern = "*/" .. FILE,
		callback = function()
			cache = {}
			refresh_soon()
		end,
	})

	local cmd = api.nvim_create_user_command
	cmd("ReviewComment", function(a)
		M.comment_range(a.line1, a.line2)
	end, { range = true, desc = "Review: comment on line(s)" })
	cmd("ReviewReply", M.reply, { desc = "Review: reply to thread" })
	cmd("ReviewResolve", M.toggle_resolved, { desc = "Review: resolve/reopen thread" })
	cmd("ReviewView", M.view, { desc = "Review: view whole thread" })
	cmd("ReviewList", function(a)
		M.list(a.bang)
	end, { bang = true, desc = "Review: open threads in quickfix (! = include resolved)" })
	cmd("ReviewOpen", M.open, { desc = "Review: open comments.md" })
	cmd("ReviewClear", function(a)
		M.clear(a.bang)
	end, { bang = true, desc = "Review: drop resolved threads (! = all)" })
	cmd("ReviewSend", M.send_to_claude, { desc = "Review: ask Claude to address threads" })

	M.refresh()
end

return M
