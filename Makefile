NVIM ?= nvim
STYLUA ?= stylua

.PHONY: test format format-check benchmark smoke-deepseek

test:
	$(NVIM) --headless -u NONE -i NONE -n +"lua require('tests.run').run()"

benchmark:
	$(NVIM) --headless -u NONE -i NONE --cmd "set noswapfile" +"luafile tests/duet_edits_bench.lua" +"luafile tests/metrics_bench.lua" +"luafile tests/cursor_tab_bench.lua" +"qa!"

smoke-deepseek:
	@test -n "$$DEEPSEEK_API_KEY" || { echo "DEEPSEEK_API_KEY is required" >&2; exit 1; }
	$(NVIM) --headless -u NONE -i NONE -n --cmd "set noswapfile" +"luafile tests/deepseek_smoke.lua"

format:
	$(STYLUA) lua/ tests/

format-check:
	$(STYLUA) --check lua/ tests/
