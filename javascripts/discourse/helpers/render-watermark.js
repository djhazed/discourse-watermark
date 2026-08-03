const MIN_FONT_PX = 6;
const MAX_FIT_PASSES = 60;

// fillText positions text by its baseline, so the only vertical space a drawn
// line occupies below its own baseline is the descender. Clearing roughly that
// much keeps stacked blocks from touching without pushing them needlessly far.
const DESCENDER_CLEARANCE = 0.35;

const parseFontSize = (font) => {
  const match = font.match(/(\d*\.?\d+)px/);
  return match ? parseFloat(match[1]) : null;
};

const scaleFont = (font, px) => font.replace(/(\d*\.?\d+)px/, `${px}px`);

// Greedily fill each line with as many tokens as fit within maxWidth.
const packTokens = (tokens, separator, maxWidth, measure) => {
  const lines = [];
  let current = "";

  tokens.forEach((token) => {
    const candidate = current === "" ? token : `${current}${separator}${token}`;

    if (current !== "" && measure(candidate) > maxWidth) {
      lines.push(current);
      current = token;
    } else {
      current = candidate;
    }
  });

  if (current !== "") {
    lines.push(current);
  }

  return lines;
};

// Shrink the font until the block fits both its width and height budget.
// Accepts a plain string, or { tokens, separator } for a wrappable block.
const layoutBlock = (
  ctx,
  value,
  font,
  maxWidth,
  maxHeight,
  lineHeightFactor
) => {
  let px = parseFontSize(font);
  let currentFont = font;
  let passes = 0;

  for (;;) {
    ctx.font = currentFont;
    const measure = (text) => ctx.measureText(text).width;

    const lines =
      typeof value === "string"
        ? [value]
        : packTokens(value.tokens, value.separator, maxWidth, measure);

    const widest = lines.length ? Math.max(...lines.map(measure)) : 0;
    const lineHeight = px === null ? 0 : px * lineHeightFactor;
    const blockHeight = lines.length * lineHeight;
    const fits = widest <= maxWidth && blockHeight <= maxHeight;

    if (fits || px === null || px <= MIN_FONT_PX || ++passes > MAX_FIT_PASSES) {
      return { lines, font: currentFont, lineHeight };
    }

    const widthRatio = widest > maxWidth ? maxWidth / widest : 1;
    const heightRatio = blockHeight > maxHeight ? maxHeight / blockHeight : 1;

    // the 0.9 cap guarantees px strictly decreases, so the loop terminates
    px = Math.max(
      MIN_FONT_PX,
      Math.floor(px * Math.min(0.9, widthRatio, heightRatio))
    );
    currentFont = scaleFont(font, px);
  }
};

const renderWatermarkDataURL = (canvas, settings, data) => {
  const {
    tile_width: width,
    tile_height: height,
    color,
    text_align,
    text_rotation,
    display_text,
    display_text_font,
    display_text_x,
    display_text_y,
    display_username_font,
    display_username_x,
    display_username_y,
    display_timestamp_font,
    display_timestamp_x,
    display_timestamp_y,
    fit_width_percent,
    line_height_percent,
    stack_blocks,
  } = settings;

  const { username, timestamp } = data;

  canvas.width = width;
  canvas.height = height;

  const ctx = canvas.getContext("2d");

  ctx.fillStyle = color;
  ctx.textAlign = text_align;
  ctx.rotate(Math.PI / (180 / parseInt(text_rotation, 10)));

  const maxWidth = width * ((parseInt(fit_width_percent, 10) || 100) / 100);
  const lineHeightFactor = (parseInt(line_height_percent, 10) || 125) / 100;

  const blocks = [
    display_text.trim() !== ""
      ? {
          value: display_text,
          font: display_text_font,
          x: parseInt(display_text_x, 10),
          y: parseInt(display_text_y, 10),
        }
      : null,
    username
      ? {
          value: username,
          font: display_username_font,
          x: parseInt(display_username_x, 10),
          y: parseInt(display_username_y, 10),
        }
      : null,
    timestamp
      ? {
          value: timestamp,
          font: display_timestamp_font,
          x: parseInt(display_timestamp_x, 10),
          y: parseInt(display_timestamp_y, 10),
        }
      : null,
  ]
    .filter(Boolean)
    .sort((a, b) => a.y - b.y);

  let cursorY = null;

  blocks.forEach((block) => {
    // stacking pushes later blocks down, so a block starts at its configured y
    // or wherever the previous block ended, whichever is lower
    const startY =
      stack_blocks && cursorY !== null ? Math.max(block.y, cursorY) : block.y;

    // the vertical budget runs from there to the bottom edge of the tile
    const budget = Math.max(1, height - startY);

    const { lines, font, lineHeight } = layoutBlock(
      ctx,
      block.value,
      block.font,
      maxWidth,
      budget,
      lineHeightFactor
    );

    ctx.font = font;
    lines.forEach((line, lineIndex) => {
      ctx.fillText(line, block.x, startY + lineIndex * lineHeight);
    });

    // baseline of the last line drawn, plus descender clearance
    cursorY =
      startY +
      (lines.length - 1) * lineHeight +
      lineHeight * DESCENDER_CLEARANCE;
  });

  return canvas.toDataURL();
};

export default renderWatermarkDataURL;
