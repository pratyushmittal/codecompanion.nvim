local h = require("tests.helpers")

local expect = MiniTest.expect
local new_set = MiniTest.new_set

local child = MiniTest.new_child_neovim()

local initial_buffer_content = {
  "function foo()",
  '    return "foo"',
  "end",
  "",
  "function bar()",
  '    return "bar"',
  "end",
  "",
  "function baz()",
  '    return "baz"',
  "end",
}

local function setup_buffer_with_content(content)
  child.lua([[
    _G.bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[_G.bufnr].readonly = false
    vim.bo[_G.bufnr].buftype = "nofile"
    vim.api.nvim_buf_set_lines(_G.bufnr, 0, -1, true, ...)
  ]], content)
end

local function get_buffer_content()
  return child.lua_get("vim.api.nvim_buf_get_lines(_G.bufnr, 0, -1, false)")
end

local function execute_editor_tool(patch_text, buffer_nr)
  buffer_nr = buffer_nr or child.lua_get("_G.bufnr")
  return child.lua([[
    local tools = {
      {
        id = "tool_1",
        type = "function",
        ["function"] = {
          name = "editor",
          arguments = {
            buffer = ...[1],
            patch_text = ...[2],
          },
        },
      },
    }
    local result = _G.agent:execute(_G.chat, tools)
    return result
  ]], buffer_nr, patch_text)
end

local T = new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "scripts/minimal_init.lua" })
      child.o.statusline = ""
      child.o.laststatus = 0
      child.lua([[_G.chat, _G.agent = require("tests.helpers").setup_chat_buffer()]])
      setup_buffer_with_content(initial_buffer_content)
    end,
    post_case = function()
      child.lua([[_G.bufnr = nil]])
    end,
    post_once = child.stop,
  },
})

T["valid_patch: simple add"] = function()
  local patch = table.concat({
    "*** Begin Patch",
    "function foo()",
    '    return "foo"',
    "end",
    "+-- new comment line",
    "",
    "function bar()",
    '    return "bar"',
    "*** End Patch",
  }, "\n")

  local result = execute_editor_tool(patch)
  expect(result[1].status).to_equal("success")

  local expected_content = {
    "function foo()",
    '    return "foo"',
    "end",
    "-- new comment line",
    "",
    "function bar()",
    '    return "bar"',
    "end",
    "",
    "function baz()",
    '    return "baz"',
    "end",
  }
  expect(get_buffer_content()).to_deep_equal(expected_content)
  expect(result[1].data.short).to_contain("Applied patch to buffer")
  expect(result[1].data.full).to_contain("```diff\n" .. patch .. "\n```")
end

T["valid_patch: simple delete"] = function()
  local patch = table.concat({
    "*** Begin Patch",
    "function foo()",
    '    return "foo"',
    "end",
    "-",
    "function bar()",
    '    return "bar"',
    "end",
    "*** End Patch",
  }, "\n")

  local result = execute_editor_tool(patch)
  expect(result[1].status).to_equal("success")

  local expected_content = {
    "function foo()",
    '    return "foo"',
    "end",
    "function bar()",
    '    return "bar"',
    "end",
    "",
    "function baz()",
    '    return "baz"',
    "end",
  }
  expect(get_buffer_content()).to_deep_equal(expected_content)
end

T["valid_patch: simple modify"] = function()
  local patch = table.concat({
    "*** Begin Patch",
    "function foo()",
    '-    return "foo"',
    '+    return "modified foo"',
    "end",
    "",
    "function bar()",
    "*** End Patch",
  }, "\n")

  local result = execute_editor_tool(patch)
  expect(result[1].status).to_equal("success")

  local expected_content = {
    "function foo()",
    '    return "modified foo"',
    "end",
    "",
    "function bar()",
    '    return "bar"',
    "end",
    "",
    "function baz()",
    '    return "baz"',
    "end",
  }
  expect(get_buffer_content()).to_deep_equal(expected_content)
end

T["valid_patch: multiple changes"] = function()
  local patch = table.concat({
    "*** Begin Patch",
    "function foo()",
    '-    return "foo"',
    '+    return "very modified foo"',
    "end",
    "",
    "function bar()",
    "",
    "function baz()",
    '-    return "baz"',
    '+    return "very modified baz"',
    "end",
    "*** End Patch",
  }, "\n")

  local result = execute_editor_tool(patch)
  expect(result[1].status).to_equal("success")

  local expected_content = {
    "function foo()",
    '    return "very modified foo"',
    "end",
    "",
    "function bar()",
    '    return "bar"',
    "end",
    "",
    "function baz()",
    '    return "very modified baz"',
    "end",
  }
  expect(get_buffer_content()).to_deep_equal(expected_content)
end

T["valid_patch: @@identifier"] = function()
  local patch = table.concat({
    "*** Begin Patch",
    "@@function bar()",
    "",
    "function bar()",
    '-    return "bar"',
    '+    return "bar modified with @@"',
    "end",
    "",
    "function baz()",
    "*** End Patch",
  }, "\n")

  local result = execute_editor_tool(patch)
  expect(result[1].status).to_equal("success")

  local expected_content = {
    "function foo()",
    '    return "foo"',
    "end",
    "",
    "function bar()",
    '    return "bar modified with @@"',
    "end",
    "",
    "function baz()",
    '    return "baz"',
    "end",
  }
  expect(get_buffer_content()).to_deep_equal(expected_content)
end

T["valid_patch: add to end of file"] = function()
  local patch = table.concat({
    "*** Begin Patch",
    "function baz()",
    '    return "baz"',
    "end",
    "+",
    "+-- new line at EOF",
    "*** End Patch",
  }, "\n")

  local result = execute_editor_tool(patch)
  expect(result[1].status).to_equal("success")

  local expected_content = {
    "function foo()",
    '    return "foo"',
    "end",
    "",
    "function bar()",
    '    return "bar"',
    "end",
    "",
    "function baz()",
    '    return "baz"',
    "end",
    "",
    "-- new line at EOF",
  }
  expect(get_buffer_content()).to_deep_equal(expected_content)
end

T["error_handling: invalid patch format - missing Begin/End"] = function()
  local patch = table.concat({
    "function foo()",
    '-    return "foo"',
    '+    return "modified foo"',
    "end",
  }, "\n")

  local result = execute_editor_tool(patch)
  expect(result[1].status).to_equal("error")
  expect(result[1].data).to_contain("Failed to parse patch_text: Invalid patch format: missing Begin/End markers")
end

T["error_handling: patch context not found"] = function()
  local patch = table.concat({
    "*** Begin Patch",
    "function non_existent_function()",
    '-    return "something"',
    '+    return "something else"',
    "end",
    "*** End Patch",
  }, "\n")

  local result = execute_editor_tool(patch)
  expect(result[1].status).to_equal("error")
  expect(result[1].data).to_contain("Failed to apply one or more changes from the patch.")
end

T["argument_validation: missing buffer"] = function()
  local patch = "*** Begin Patch\n+test\n*** End Patch"
  local result = execute_editor_tool(patch, nil) -- Explicitly pass nil for buffer
  expect(result[1].status).to_equal("error")
  expect(result[1].data).to_equal("No buffer number or buffer number conversion failed")
end

T["argument_validation: invalid buffer"] = function()
  local patch = "*** Begin Patch\n+test\n*** End Patch"
  local result = execute_editor_tool(patch, 99999) -- Invalid buffer number
  expect(result[1].status).to_equal("error")
  expect(result[1].data).to_equal("Invalid buffer number")
end

T["argument_validation: missing patch_text"] = function()
  local result = execute_editor_tool(nil)
  expect(result[1].status).to_equal("error")
  expect(result[1].data).to_equal("No patch_text provided")

  result = execute_editor_tool("") -- Empty patch_text
  expect(result[1].status).to_equal("error")
  expect(result[1].data).to_equal("No patch_text provided")
end

T["valid_patch: apply to empty buffer"] = function()
  setup_buffer_with_content({}) -- Setup empty buffer

  local patch = table.concat({
    "*** Begin Patch",
    "+-- This is a new file",
    "+function new_func()",
    '+  return "new"',
    "+end",
    "*** End Patch",
  }, "\n")

  local result = execute_editor_tool(patch)
  expect(result[1].status).to_equal("success")

  local expected_content = {
    "-- This is a new file",
    "function new_func()",
    '  return "new"',
    "end",
  }
  expect(get_buffer_content()).to_deep_equal(expected_content)
end

return T
