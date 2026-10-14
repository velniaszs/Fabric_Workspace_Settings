-- Pandoc Lua filter for the Word build.
--  * The first level-1 heading is removed - the title page carries the document name.
--  * Every other heading moves up one level, so "## 1. The problem" becomes Heading 1.
--  * The hand-written "Contents" list is removed - Word builds a real table of contents.
--  * Diagrams are sized from their pixel dimensions to fit the page, and centred.

-- A4 text area with 2.2 cm margins, leaving room for a heading above a tall diagram.
local MAX_W_CM = 16.6
local MAX_H_CM = 21.5
-- Diagrams are rendered at twice their CSS size, so 192 pixels make one inch.
local PX_PER_CM = 192 / 2.54

local function plain(inlines)
  return pandoc.utils.stringify(inlines)
end

local function sized(img)
  local ok, _, contents = pcall(pandoc.mediabag.fetch, img.src)
  if not ok or not contents then return img end
  local ok2, size = pcall(pandoc.image.size, contents)
  if not ok2 or not size then return img end

  local w = size.width / PX_PER_CM
  local h = size.height / PX_PER_CM
  if w > MAX_W_CM then h = h * MAX_W_CM / w; w = MAX_W_CM end
  if h > MAX_H_CM then w = w * MAX_H_CM / h; h = MAX_H_CM end
  img.attributes.width = string.format("%.2fcm", w)
  img.attributes.height = string.format("%.2fcm", h)
  return img
end

function Pandoc(doc)
  local out = {}
  local title_done = false
  local skipping_level = nil

  for _, block in ipairs(doc.blocks) do
    local keep = true

    if block.t == "Header" then
      if skipping_level and block.level <= skipping_level then
        skipping_level = nil
      end
      if not title_done and block.level == 1 then
        title_done = true
        keep = false
      elseif plain(block.content) == "Contents" then
        skipping_level = block.level
        keep = false
      end
    end

    -- Inside the hand-written Contents section only the list itself is dropped, so a diagram or
    -- a note that follows it survives.
    if skipping_level and keep and block.t ~= "Header" then
      keep = not (block.t == "BulletList" or block.t == "OrderedList")
    end

    if keep then
      if block.t == "Header" and block.level > 1 then
        block.level = block.level - 1
      end
      table.insert(out, block)
    end
  end

  doc.blocks = out
  return doc
end

-- A paragraph holding only a diagram becomes a centred "Figure" paragraph.
function Para(para)
  if #para.content == 1 and para.content[1].t == "Image" then
    local img = sized(para.content[1])
    return pandoc.Div({ pandoc.Para({ img }) }, { ["custom-style"] = "Figure" })
  end
end

function Figure(fig)
  return pandoc.walk_block(fig, { Image = sized })
end

-- A horizontal rule between sections is redundant once each section starts a new page.
function HorizontalRule()
  return {}
end
