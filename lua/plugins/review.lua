-- Local GitLab-style review threads (lua/review.lua): comment in diffview,
-- then <leader>rs hands the threads to Claude's /review-comments skill.
local function review(fn, ...)
	local args = { ... }
	return function()
		require("review")[fn](unpack(args))
	end
end

return {
	name = "review",
	dir = vim.fn.stdpath("config"),
	virtual = true,
	event = "VeryLazy",
	config = function()
		require("review").setup()
	end,
	keys = {
		{ "<leader>r", nil, desc = "[R]eview" },
		{ "<leader>rc", review("comment"), mode = { "n", "x" }, desc = "Review: comment on line(s)" },
		{ "<leader>rr", review("reply"), desc = "Review: reply to thread" },
		{ "<leader>rx", review("toggle_resolved"), desc = "Review: resolve/reopen thread" },
		{ "<leader>rv", review("view"), desc = "Review: view whole thread" },
		{ "<leader>rl", review("list"), desc = "Review: list open threads" },
		{ "<leader>rL", review("list", true), desc = "Review: list all threads" },
		{ "<leader>ro", review("open"), desc = "Review: open comments.md" },
		{ "<leader>rh", review("toggle_show_resolved"), desc = "Review: show/hide resolved" },
		{ "<leader>rs", review("send_to_claude"), desc = "Review: send to Claude" },
	},
}
