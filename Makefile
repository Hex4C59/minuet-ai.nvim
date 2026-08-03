NVIM ?= nvim
STYLUA ?= stylua

.PHONY: test format format-check benchmark smoke-deepseek

test:
	$(NVIM) --headless -u NONE -i NONE -n +"lua require('tests.run').run()"

benchmark:
	$(NVIM) --headless -u NONE -i NONE --cmd "set noswapfile" +"luafile tests/bench/duet_edits.lua" +"luafile tests/bench/metrics.lua" +"luafile tests/bench/cursor_tab.lua" +"qa!"

smoke-deepseek:
	@test -n "$$DEEPSEEK_API_KEY" || { echo "DEEPSEEK_API_KEY is required" >&2; exit 1; }
	$(NVIM) --headless -u NONE -i NONE -n --cmd "set noswapfile" +"luafile tests/smoke/deepseek.lua"

format:
	$(STYLUA) lua/ tests/

format-check:
	$(STYLUA) --check lua/ tests/
