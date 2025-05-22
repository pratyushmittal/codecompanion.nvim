local h = require("tests.helpers")

local new_set = MiniTest.new_set

local child = MiniTest.new_child_neovim()
local T = new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "scripts/minimal_init.lua" })
      child.o.statusline = ""
      child.o.laststatus = 0
      child.lua([[
        _G.TEST_TMPFILE = vim.fn.stdpath('cache') .. '/codecompanion/tests/cc_test_file.txt'

        -- ensure no leftover from previous run
        pcall(vim.loop.fs_unlink, _G.TEST_TMPFILE)

        h = require('tests.helpers')
        chat, agent = h.setup_chat_buffer()

        -- Load the module containing apply_change and other necessary functions
        _G.FilesModule = require("codecompanion.strategies.chat.agents.tools.files")

        -- Make CompareLines available in the global scope for test functions
        _G.CompareLines = function(lines1, lines2)
          if lines1 == nil and lines2 == nil then return true end
          if lines1 == nil or lines2 == nil then return false end
          if #lines1 ~= #lines2 then return false end
          for i = 1, #lines1 do
            if lines1[i] ~= lines2[i] then return false end
          end
          return true
        end
      ]])
    end,
    post_case = function()
      child.lua([[
        pcall(vim.loop.fs_unlink, _G.TEST_TMPFILE)
        h.teardown_chat_buffer()
      ]])
    end,
    post_once = child.stop,
  },
})

T["files tool create action"] = function()
  child.lua([[
    --require("tests.log")
    local tool = {
      {
        ["function"] = {
          name = "files",
          arguments = string.format('{"action": "CREATE", "path": "%s", "contents": "import pygame\\nimport time\\nimport random\\n"}', _G.TEST_TMPFILE)
        },
      },
    }
    agent:execute(chat, tool)
    vim.wait(200)
  ]])

  -- Test that the file was created
  local output = child.lua_get("vim.fn.readfile(_G.TEST_TMPFILE)")
  h.eq(output, { "import pygame", "import time", "import random" }, "File was not created")

  -- expect.reference_screenshot(child.get_screenshot())
end

T["files tool read action"] = function()
  child.lua([[
    -- Create a test file with known contents
    local contents = { "alpha", "beta", "gamma" }
    local ok = vim.fn.writefile(contents, _G.TEST_TMPFILE)
    assert(ok == 0)
    local tool = {
      {
        ["function"] = {
          name = "files",
          arguments = string.format('{"action": "READ", "path": "%s", "contents": null}', _G.TEST_TMPFILE)
        },
      },
    }
    agent:execute(chat, tool)
    vim.wait(200)
  ]])

  local output = child.lua_get("chat.messages[#chat.messages].content")
  h.eq("alpha", string.match(output, "alpha"))
  h.eq("beta", string.match(output, "beta"))
  h.eq("gamma", string.match(output, "gamma"))
end

T["files tool delete action"] = function()
  child.lua([[
    -- Create a test file to delete
    local contents = { "to be deleted" }
    local ok = vim.fn.writefile(contents, _G.TEST_TMPFILE)
    assert(ok == 0)
    local tool = {
      {
        ["function"] = {
          name = "files",
          arguments = string.format('{"action": "DELETE", "path": "%s"}', _G.TEST_TMPFILE)
        },
      },
    }
    agent:execute(chat, tool)
    vim.wait(200)
  ]])

  -- Test that the file was deleted
  local deleted = child.lua_get("vim.loop.fs_stat(_G.TEST_TMPFILE) == nil")
  h.eq(deleted, true, "File was not deleted")
end

T["files tool update action"] = function()
  child.lua([[
      -- create initial file
      local initial = "line1\nline2\nline3"
      local ok = vim.fn.writefile(vim.split(initial, "\n"), _G.TEST_TMPFILE)
      assert(ok == 0)
      local tool = {
        {
          ["function"] = {
            name = "files",
            arguments = string.format('{"action": "UPDATE", "path": "%s", "contents": "*** Begin Patch\\nline1\\n-line2\\n+new_line2\\nline3\\n*** End Patch"}', _G.TEST_TMPFILE)
          },
        },
      }
      agent:execute(chat, tool)
      vim.wait(200)
    ]])

  -- Test that the file was updated
  local output = child.lua_get("vim.fn.readfile(_G.TEST_TMPFILE)")
  h.eq(output, { "line1", "new_line2", "line3" }, "File was not updated")
end

T["files tool regex"] = function()
  child.lua([[
      -- create initial file
      local initial = "line1\nline2\nline3"
      local ok = vim.fn.writefile(vim.split(initial, "\n"), _G.TEST_TMPFILE)
      assert(ok == 0)
      local tool = {
        {
          ["function"] = {
            name = "files",
            arguments = string.format('{"action": "UPDATE", "path": "%s", "contents": "*** Begin Patch\\n-line2\\n*** End Patch\\n"}', _G.TEST_TMPFILE)
          },
        },
      }
      agent:execute(chat, tool)
      vim.wait(200)
    ]])

  -- Test that the file was updated
  local output = child.lua_get("vim.fn.readfile(_G.TEST_TMPFILE)")
  h.eq(output, { "line1", "line3" }, "File was not updated")
end

T["files tool update from fixtures"] = function()
  child.lua([[
      -- read initial file from fixture
      local initial = vim.fn.readfile("tests/fixtures/files-input-1.html")
      local ok = vim.fn.writefile(initial, _G.TEST_TMPFILE)
      assert(ok == 0)
      -- read contents for the tool from fixtures
      local patch_contents = table.concat(vim.fn.readfile("tests/fixtures/files-diff-1.patch"), "\n")
      local arguments = vim.json.encode({ action = "UPDATE", path = _G.TEST_TMPFILE, contents = patch_contents })
      local tool = {
        {
          ["function"] = {
            name = "files",
            arguments = arguments
          },
        },
      }
      agent:execute(chat, tool)
      vim.wait(200)
    ]])

  -- Test that the file was updated as per the output fixture
  local output = child.lua_get("vim.fn.readfile(_G.TEST_TMPFILE)")
  local expected = child.lua_get("vim.fn.readfile('tests/fixtures/files-output-1.html')")
  h.eq_info(output, expected, child.lua_get("chat.messages[#chat.messages].content"))
end

T["files tool update multiple @@"] = function()
  child.lua([[
      -- read initial file from fixture
      local initial = vim.fn.readfile("tests/fixtures/files-input-1.html")
      local ok = vim.fn.writefile(initial, _G.TEST_TMPFILE)
      assert(ok == 0)
      -- read contents for the tool from fixtures
      local patch_contents = table.concat(vim.fn.readfile("tests/fixtures/files-diff-2.patch"), "\n")
      local arguments = vim.json.encode({ action = "UPDATE", path = _G.TEST_TMPFILE, contents = patch_contents })
      local tool = {
        {
          ["function"] = {
            name = "files",
            arguments = arguments
          },
        },
      }
      agent:execute(chat, tool)
      vim.wait(200)
    ]])

  -- Test that the file was updated as per the output fixture
  local output = child.lua_get("vim.fn.readfile(_G.TEST_TMPFILE)")
  local expected = child.lua_get("vim.fn.readfile('tests/fixtures/files-output-2.html')")
  h.eq_info(output, expected, child.lua_get("chat.messages[#chat.messages].content"))
end

T["files tool update empty lines"] = function()
  child.lua([[
      -- read initial file from fixture
      local initial = vim.fn.readfile("tests/fixtures/files-input-1.html")
      local ok = vim.fn.writefile(initial, _G.TEST_TMPFILE)
      assert(ok == 0)
      -- read contents for the tool from fixtures
      local patch_contents = table.concat(vim.fn.readfile("tests/fixtures/files-diff-3.patch"), "\n")
      local arguments = vim.json.encode({ action = "UPDATE", path = _G.TEST_TMPFILE, contents = patch_contents })
      local tool = {
        {
          ["function"] = {
            name = "files",
            arguments = arguments
          },
        },
      }
      agent:execute(chat, tool)
      vim.wait(200)
    ]])

  -- Test that the file was updated as per the output fixture
  local output = child.lua_get("vim.fn.readfile(_G.TEST_TMPFILE)")
  local expected = child.lua_get("vim.fn.readfile('tests/fixtures/files-output-3.html')")
  h.eq_info(output, expected, child.lua_get("chat.messages[#chat.messages].content"))
end

T["files tool update multiple continuation"] = function()
  child.lua([[
      -- read initial file from fixture
      local initial = vim.fn.readfile("tests/fixtures/files-input-4.html")
      local ok = vim.fn.writefile(initial, _G.TEST_TMPFILE)
      assert(ok == 0)
      -- read contents for the tool from fixtures
      local patch_contents = table.concat(vim.fn.readfile("tests/fixtures/files-diff-4.patch"), "\n")
      local arguments = vim.json.encode({ action = "UPDATE", path = _G.TEST_TMPFILE, contents = patch_contents })
      local tool = {
        {
          ["function"] = {
            name = "files",
            arguments = arguments
          },
        },
      }
      agent:execute(chat, tool)
      vim.wait(200)
    ]])

  -- Test that the file was updated as per the output fixture
  local output = child.lua_get("vim.fn.readfile(_G.TEST_TMPFILE)")
  local expected = child.lua_get("vim.fn.readfile('tests/fixtures/files-output-4.html')")
  h.eq_info(output, expected, child.lua_get("chat.messages[#chat.messages].content"))
end

T["files tool update spaces"] = function()
  child.lua([[
      -- read initial file from fixture
      local initial = vim.fn.readfile("tests/fixtures/files-input-4.html")
      local ok = vim.fn.writefile(initial, _G.TEST_TMPFILE)
      assert(ok == 0)
      -- read contents for the tool from fixtures
      local patch_contents = table.concat(vim.fn.readfile("tests/fixtures/files-diff-4.2.patch"), "\n")
      local arguments = vim.json.encode({ action = "UPDATE", path = _G.TEST_TMPFILE, contents = patch_contents })
      local tool = {
        {
          ["function"] = {
            name = "files",
            arguments = arguments
          },
        },
      }
      agent:execute(chat, tool)
      vim.wait(200)
    ]])

  -- Test that the file was updated as per the output fixture
  local output = child.lua_get("vim.fn.readfile(_G.TEST_TMPFILE)")
  local expected = child.lua_get("vim.fn.readfile('tests/fixtures/files-output-4.html')")
  h.eq_info(output, expected, child.lua_get("chat.messages[#chat.messages].content"))
end

T["files tool update html spaces flexible"] = function()
  child.lua([[
      -- read initial file from fixture
      local initial = vim.fn.readfile("tests/fixtures/files-input-5.html")
      local ok = vim.fn.writefile(initial, _G.TEST_TMPFILE)
      assert(ok == 0)
      -- read contents for the tool from fixtures
      local patch_contents = table.concat(vim.fn.readfile("tests/fixtures/files-diff-5.patch"), "\n")
      local arguments = vim.json.encode({ action = "UPDATE", path = _G.TEST_TMPFILE, contents = patch_contents })
      local tool = {
        {
          ["function"] = {
            name = "files",
            arguments = arguments
          },
        },
      }
      agent:execute(chat, tool)
      vim.wait(200)
    ]])

  -- Test that the file was updated as per the output fixture
  local output = child.lua_get("vim.fn.readfile(_G.TEST_TMPFILE)")
  local expected = child.lua_get("vim.fn.readfile('tests/fixtures/files-output-5.html')")
  h.eq_info(output, expected, child.lua_get("chat.messages[#chat.messages].content"))
end

T["files tool update html line breaks"] = function()
  child.lua([[
      -- read initial file from fixture
      local initial = vim.fn.readfile("tests/fixtures/files-input-6.html")
      local ok = vim.fn.writefile(initial, _G.TEST_TMPFILE)
      assert(ok == 0)
      -- read contents for the tool from fixtures
      local patch_contents = table.concat(vim.fn.readfile("tests/fixtures/files-diff-6.patch"), "\n")
      local arguments = vim.json.encode({ action = "UPDATE", path = _G.TEST_TMPFILE, contents = patch_contents })
      local tool = {
        {
          ["function"] = {
            name = "files",
            arguments = arguments
          },
        },
      }
      agent:execute(chat, tool)
      vim.wait(200)
    ]])

  -- Test that the file was updated as per the output fixture
  local output = child.lua_get("vim.fn.readfile(_G.TEST_TMPFILE)")
  local expected = child.lua_get("vim.fn.readfile('tests/fixtures/files-output-6.html')")
  h.eq_info(output, expected, child.lua_get("chat.messages[#chat.messages].content"))
end

T["files tool update lua dashes"] = function()
  child.lua([[
      -- read initial file from fixture
      local initial = vim.fn.readfile("tests/fixtures/files-input-7.lua")
      local ok = vim.fn.writefile(initial, _G.TEST_TMPFILE)
      assert(ok == 0)
      -- read contents for the tool from fixtures
      local patch_contents = table.concat(vim.fn.readfile("tests/fixtures/files-diff-7.patch"), "\n")
      local arguments = vim.json.encode({ action = "UPDATE", path = _G.TEST_TMPFILE, contents = patch_contents })
      local tool = {
        {
          ["function"] = {
            name = "files",
            arguments = arguments
          },
        },
      }
      agent:execute(chat, tool)
      vim.wait(200)
    ]])

  -- Test that the file was updated as per the output fixture
  local output = child.lua_get("vim.fn.readfile(_G.TEST_TMPFILE)")
  local expected = child.lua_get("vim.fn.readfile('tests/fixtures/files-output-7.lua')")
  h.eq_info(output, expected, child.lua_get("chat.messages[#chat.messages].content"))
end

-- NOTE: compare_lines is now defined in the pre_case hook as _G.CompareLines
-- apply_change_test_cases is defined below and passed to child.lua context as _G.ApplyChangeTestCases

local apply_change_test_cases = {
    {
      name = "Perfect match",
      initial_lines = {"line1", "line2", "line3", "old_line", "line5", "line6", "line7"},
      change = {pre = {"line1", "line2", "line3"}, old = {"old_line"}, new = {"new_line"}, post = {"line5", "line6", "line7"}, focus = {}},
      expected_lines = {"line1", "line2", "line3", "new_line", "line5", "line6", "line7"},
    },
    {
      name = "Slightly mismatched pre context (1/3 diff), should pass",
      initial_lines = {"line_A", "line_B_original", "line_C", "old_content", "line_D", "line_E", "line_F"},
      change = {pre = {"line_A", "line_B_modified", "line_C"}, old = {"old_content"}, new = {"new_content"}, post = {"line_D", "line_E", "line_F"}, focus = {}},
      expected_lines = {"line_A", "line_B_original", "line_C", "new_content", "line_D", "line_E", "line_F"},
    },
    {
      name = "Slightly mismatched post context (1/3 diff), should pass",
      initial_lines = {"line_A", "line_B", "line_C", "old_content", "line_D_original", "line_E", "line_F"},
      change = {pre = {"line_A", "line_B", "line_C"}, old = {"old_content"}, new = {"new_content"}, post = {"line_D_modified", "line_E", "line_F"}, focus = {}},
      expected_lines = {"line_A", "line_B", "line_C", "new_content", "line_D_original", "line_E", "line_F"},
    },
    {
      name = "Match with trim_spaces = true (indentation difference in pre/post)",
      initial_lines = {"  line1", "    line2", "  line3", "  old_line", "    line5", "  line6"},
      change = {pre = {"line1", "line2", "line3"}, old = {"old_line"}, new = {"new_line"}, post = {"line5", "line6"}, focus = {}},
      expected_lines = {"  line1", "    line2", "  line3", "  new_line", "    line5", "  line6"},
    },
    {
      name = "Match with trim_spaces = true (indentation difference in old line, fix_spaces applies)",
      initial_lines = {"  line1", "    old_line_indented", "  line3"},
      change = {pre = {"  line1"}, old = {"old_line_indented"}, new = {"new_line_inserted"}, post = {"  line3"}, focus = {}},
      expected_lines = {"  line1", "    new_line_inserted", "  line3"},
    },
    {
      name = "Match with trim_spaces = true (patch has extra space in old line, fix_spaces applies)",
      initial_lines = {"  line1", "    old_line_indented", "  line3"},
      change = {pre = {"  line1"}, old = {" old_line_indented"}, new = {"new_line_inserted"}, post = {"  line3"}, focus = {}},
      expected_lines = {"  line1", "    new_line_inserted", "  line3"},
    },
    {
      name = "Rejected: old lines do not match even if context is good",
      initial_lines = {"line1", "line2", "line3", "actual_old_line", "line5", "line6", "line7"},
      change = {pre = {"line1", "line2", "line3"}, old = {"expected_old_line_differs"}, new = {"new_line"}, post = {"line5", "line6", "line7"}, focus = {}},
      expected_lines = nil, -- Expect rejection
    },
    {
      name = "Rejected: very low context probability (all context lines mismatch)",
      initial_lines = {"line1", "line2", "line3", "old_line", "line5", "line6", "line7"},
      change = {pre = {"X", "Y", "Z"}, old = {"old_line"}, new = {"new_line"}, post = {"A", "B", "C"}, focus = {}},
      expected_lines = nil, -- Expect rejection
    },
    {
      name = "Pure insertion (no pre, post, old)",
      initial_lines = {"line_before", "line_after"},
      change = {pre = {}, old = {}, new = {"inserted_line1", "inserted_line2"}, post = {}, focus = {}},
      expected_lines = {"inserted_line1", "inserted_line2", "line_before", "line_after"},
    },
    {
      name = "Pure insertion at end of file",
      initial_lines = {"line_A", "line_B"},
      change = {pre = {"line_A", "line_B"}, old = {}, new = {"inserted_line_C"}, post = {}, focus = {}},
      expected_lines = {"line_A", "line_B", "inserted_line_C"},
    },
    {
      name = "Insertion with pre context",
      initial_lines = {"context_A", "context_B", "follow_line"},
      change = {pre = {"context_A", "context_B"}, old = {}, new = {"inserted_here"}, post = {}, focus = {}},
      expected_lines = {"context_A", "context_B", "inserted_here", "follow_line"},
    },
    {
      name = "Insertion with post context (less common, but test)",
      initial_lines = {"pre_line", "context_A", "context_B"},
      change = {pre = {}, old = {}, new = {"inserted_here"}, post = {"context_A", "context_B"}, focus = {}},
      expected_lines = {"pre_line", "inserted_here", "context_A", "context_B"},
    },
    {
      name = "Deletion of a line",
      initial_lines = {"line_A", "line_to_delete", "line_B"},
      change = {pre = {"line_A"}, old = {"line_to_delete"}, new = {}, post = {"line_B"}, focus = {}},
      expected_lines = {"line_A", "line_B"},
    },
    {
      name = "Appending to file (old lines are empty, pre is last lines of file)",
      initial_lines = {"last_line_1", "last_line_2"},
      change = {pre = {"last_line_1", "last_line_2"}, old = {}, new = {"appended_line"}, post = {}, focus = {}},
      expected_lines = {"last_line_1", "last_line_2", "appended_line"},
    },
    {
      name = "Focus line respected",
      initial_lines = {"header", "content1", "target_focus", "content2", "old_line_here", "content3"},
      change = {pre = {"content2"}, old = {"old_line_here"}, new = {"new_line_here"}, post = {"content3"}, focus = {"target_focus"}},
      expected_lines = {"header", "content1", "target_focus", "content2", "new_line_here", "content3"},
    },
    {
      name = "Focus line respected (trim_spaces)",
      initial_lines = {"  header", "  content1", "  target_focus  ", "  content2", "    old_line_here", "  content3"},
      change = {pre = {"content2"}, old = {"old_line_here"}, new = {"new_line_here"}, post = {"content3"}, focus = {"target_focus"}},
      expected_lines = {"  header", "  content1", "  target_focus  ", "  content2", "    new_line_here", "  content3"},
    },
    {
      name = "Focus line not found, patch rejected",
      initial_lines = {"header", "content1", "other_content", "content2", "old_line_here", "content3"},
      change = {pre = {"content2"}, old = {"old_line_here"}, new = {"new_line_here"}, post = {"content3"}, focus = {"missing_target_focus"}},
      expected_lines = nil,
    },
    {
        name = "Insertion with trim_spaces and pre-context to guide indentation",
        initial_lines = {"function example()", "    return true", "end"},
        change = {
            pre = {"    return true"}, old = {}, new = {"-- new comment line"}, post = {}, focus = {"function example()"}
        },
        expected_lines = {"function example()", "    return true", "    -- new comment line", "end"},
    },
    {
        name = "Insertion at start of file with post-context to guide indentation (no fix_spaces expected)",
        initial_lines = {"    first_line_indented", "    second_line_indented"},
        change = {
            pre = {}, old = {}, new = {"newline_at_start"}, post = {"    first_line_indented"} , focus = {}
        },
        expected_lines = {"newline_at_start", "    first_line_indented", "    second_line_indented"},
    },
}

-- Pass the test cases to the child neovim context
child.lua([[
  _G.ApplyChangeTestCases = vim.deepcopy(...)
]], apply_change_test_cases)


-- Dynamically generate test functions for each case
for idx, tc_data in ipairs(apply_change_test_cases) do
  local test_name = string.format("apply_change: %s (TC %d)", tc_data.name, idx)
  T[test_name] = function()
    child.lua([[
      local current_tc_idx = ...
      local tc = _G.ApplyChangeTestCases[current_tc_idx]

      -- Deepcopy initial_lines as apply_change might modify it or its subtables if not careful
      local current_initial_lines = vim.deepcopy(tc.initial_lines)
      local actual_new_lines = _G.FilesModule.apply_change(current_initial_lines, tc.change)
      local pass = _G.CompareLines(actual_new_lines, tc.expected_lines)

      if not pass then
        -- Construct a detailed failure message
        local msg = string.format("Test FAILED: %s\nExpected: %s\nActual:   %s",
                                  tc.name,
                                  vim.inspect(tc.expected_lines),
                                  vim.inspect(actual_new_lines))
        -- Optionally print more details about the change object itself
        -- msg = msg .. "\nChange object: " .. vim.inspect(tc.change)
        assert(false, msg)
      else
        -- Optional: print a success message for each test case if needed for debugging,
        -- but MiniTest usually only shows failures.
        -- print("Test PASSED: " .. tc.name)
        assert(true) -- Indicate test success explicitly
      end
    ]], idx) -- Pass the index to the child.lua context
  end
end

return T
