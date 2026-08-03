import Component from "@glimmer/component";
import { action } from "@ember/object";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import { schedule } from "@ember/runloop";
import { inject as service } from "@ember/service";
import Category from "discourse/models/category";
import { getComputedColor, getComputedFont } from "../helpers/computed-values";
import renderWatermarkDataURL from "../helpers/render-watermark";

const RADIX = { binary: 2, hex: 16 };

const DEFAULT_DATETIME_PATTERN = "MMDDYYYYHHmm";

// digits needed to represent one 8-bit character in each base
const CHAR_WIDTH = { binary: 8, hex: 2 };

// "jsm", binary -> ["01101010", "01110011", "01101101"]
// "jsm", hex    -> ["6A", "73", "6D"]
const asciiTokens = (value, radix, width) =>
  Array.from(String(value)).map((char) =>
    char.codePointAt(0).toString(radix).padStart(width, "0").toUpperCase()
  );

// Flattens either shape into one line, for the corner label.
const toText = (value) => {
  if (value === null || value === undefined) {
    return "";
  }

  return typeof value === "string"
    ? value
    : value.tokens.join(value.separator);
};

// Returns a plain string, or { tokens, separator } for a wrappable encoded block.
// `minDigits` left-pads the numeric encodings with zeros to a fixed width; it is
// a minimum, never a truncation, so a value longer than minDigits is untouched.
const encode = (mode, { plain, numeric }, base, minDigits) => {
  const radix = RADIX[base] || RADIX.binary;

  if (mode === "compact" || mode === "datetime") {
    if (!Number.isFinite(Number(numeric))) {
      return null;
    }

    const digits = Number(numeric).toString(radix).toUpperCase();
    const width = parseInt(minDigits, 10);

    return width > 0 ? digits.padStart(width, "0") : digits;
  }

  if (mode === "ascii") {
    return {
      tokens: asciiTokens(plain, radix, CHAR_WIDTH[base] || CHAR_WIDTH.binary),
      separator: " "
    };
  }

  return plain;
};

export default class WatermarkBackground extends Component {
  @service appEvents;
  @service currentUser;
  @service router;
  @service siteSettings;

  REFRESH_EVENTS = [
    // render on every page chance
    "page:changed",
    // updates the watermark again if the header of the topic was updated
    // in case the category or tags were edited
    "header:update-topic"
  ];

  onlyInCategories = settings.only_in_categories
    .split("|")
    .filter((id) => id !== "")
    .map((v) => parseInt(v, 10));
  exceptInCategories = settings.except_in_categories
    .split("|")
    .filter((id) => id !== "")
    .map((v) => parseInt(v, 10));
  onlyInTags = settings.only_in_tags.split("|").filter((id) => id !== "");
  exceptInTags = settings.except_in_tags.split("|").filter((id) => id !== "");
  urlRegexps = settings.or_if_url_matches
    .split("|")
    .filter((id) => id !== "")
    .map((v) => new RegExp(v));

  #domElement;
  #cornerElement;

  constructor() {
    super(...arguments);
    this.REFRESH_EVENTS.forEach((eventName) =>
      this.appEvents.on(eventName, this, this.refreshWatermark)
    );
  }

  willDestroy() {
    super.willDestroy(...arguments);
    this.REFRESH_EVENTS.forEach((eventName) =>
      this.appEvents.off(eventName, this, this.refreshWatermark)
    );
  }

  get currentCategories() {
    const currentRoute = this.router.currentRoute;

    if (currentRoute === null) {
      return [];
    }

    let category = null;

    // topics
    if (
      currentRoute.name === "topic.fromParams" ||
      currentRoute.name === "topic.fromParamsNear"
    ) {
      category = Category.findById(currentRoute.parent.attributes.category_id);
    }

    // categories
    if (currentRoute.params.category_slug_path_with_id) {
      category = Category.findBySlugPathWithID(
        currentRoute.params.category_slug_path_with_id
      );
    }

    if (category) {
      const categories = [category.id];

      // just in case there is some discourse out there with more than two levels of categories
      do {
        categories.push(category.parent_category_id);
        category = category.parentCategory;
      } while (category && category.parentCategory);

      return categories.filter((id) => id != null);
    }

    return [];
  }

  get currentTags() {
    const currentRoute = this.router.currentRoute;

    if (currentRoute === null) {
      return [];
    }

    // topics
    if (
      currentRoute.name === "topic.fromParams" ||
      currentRoute.name === "topic.fromParamsNear"
    ) {
      return currentRoute.parent.attributes.tags;
    }

    // categories
    if (currentRoute.params.tag_id) {
      return [currentRoute.params.tag_id];
    }

    return [];
  }

  get shouldShowWatermark() {
    const router = this.router;

    // check if there something to be rendered in the first place
    if (
      !(
        settings.display_text.trim() !== "" ||
        settings.display_username ||
        settings.display_timestamp
      )
    ) {
      return false;
    }

    let showWatermark;

    // PR by pfaffman
    showWatermark = this.siteSettings.title.match(
      settings.if_site_title_matches
    );

    // watermark applied by categories
    if (
      showWatermark &&
      (this.onlyInCategories.length > 0 || this.exceptInCategories.length > 0)
    ) {
      const categories = this.currentCategories;

      const testOnlyCategories =
        this.onlyInCategories.length === 0 ||
        categories.find((id) => this.onlyInCategories.indexOf(id) > -1);
      const testExceptCategories =
        testOnlyCategories &&
        (this.exceptInCategories.length === 0 ||
          categories.every((id) => this.exceptInCategories.indexOf(id) === -1));
      showWatermark = testOnlyCategories && testExceptCategories;
    }

    // watermark applied by tags
    // note that the test will be additive (&&) to the categories filter
    if (
      showWatermark &&
      (this.onlyInTags.length > 0 || this.exceptInTags.length > 0)
    ) {
      const tags = this.currentTags;

      const testOnlyTags =
        this.onlyInTags.length === 0 ||
        tags.find((id) => this.onlyInTags.indexOf(id) > -1);
      const testExceptTags =
        testOnlyTags &&
        (this.exceptInTags.length === 0 ||
          tags.every((id) => this.exceptInTags.indexOf(id) === -1));
      showWatermark = testOnlyTags && testExceptTags;
    }

    for (const regex of this.urlRegexps) {
      showWatermark = showWatermark || regex.test(router.currentURL);
      if (showWatermark) {
        break;
      }
    }

    return showWatermark;
  }

  @action
  setDomElement(element) {
    this.#domElement = element;
  }

  @action
  setCornerElement(element) {
    this.#cornerElement = element;
  }

  // The corner label is a plain DOM node rather than part of the tiled canvas,
  // so it is never rotated and is positioned by CSS class instead of x/y.
  @action
  renderCornerLabel(username, timestamp) {
    const cornerDiv = this.#cornerElement;

    if (!cornerDiv) {
      return;
    }

    const parts = [toText(username), toText(timestamp)].filter(
      (part) => part !== ""
    );

    if (!settings.show_corner_label || parts.length === 0) {
      cornerDiv.textContent = "";
      cornerDiv.style.display = "none";
      return;
    }

    cornerDiv.textContent = parts.join(" / ");
    cornerDiv.className = settings.corner_label_position || "bottom-right";
    cornerDiv.style.color = settings.corner_label_color;
    cornerDiv.style.font = settings.corner_label_font;
    cornerDiv.style.display = "block";
  }

  @action
  refreshWatermark() {
    schedule("afterRender", () => {
      if (this.shouldShowWatermark) {
        this.renderWatermark();
        return;
      }

      this.clearWatermark();
    });
  }

  @action
  clearWatermark() {
    const watermarkDiv = this.#domElement;
    watermarkDiv.style.backgroundImage = "";

    if (this.#cornerElement) {
      this.#cornerElement.textContent = "";
      this.#cornerElement.style.display = "none";
    }
  }

  @action
  renderWatermark() {
    const watermarkDiv = this.#domElement;
    const canvas = document.createElement("canvas");

    // we will use the dom element to resolve the CSS color even if
    // the user specify a CSS variable
    const resolvedColor = getComputedColor(watermarkDiv, settings.color);

    // now we will use the same trick to resolve the fonts
    const resolvedTextFont = getComputedFont(
      watermarkDiv,
      settings.display_text_font
    );
    const resolvedUsernameFont = getComputedFont(
      watermarkDiv,
      settings.display_username_font
    );
    const resolvedTimestampFont = getComputedFont(
      watermarkDiv,
      settings.display_timestamp_font
    );

    let username = null;
    if (settings.display_username && this.currentUser) {
      username = encode(
        settings.username_encoding,
        { plain: this.currentUser.username, numeric: this.currentUser.id },
        settings.encoding_radix,
        settings.compact_username_digits
      );
    }

    let timestamp = null;
    if (settings.display_timestamp) {
      const mode = settings.timestamp_encoding;

      // "datetime" packs the calendar fields straight into one number, so the
      // decoded decimal reads off as the pattern itself with no epoch maths.
      // Non-digits are stripped, so a pattern may contain separators for
      // readability; only the digit count matters when decoding.
      // Everything else uses seconds since the Unix epoch, which every epoch
      // converter understands without a multiplier.
      const numeric =
        mode === "datetime"
          ? Number(
              moment()
                .format(settings.datetime_pattern || DEFAULT_DATETIME_PATTERN)
                .replace(/\D/g, "")
            )
          : Math.floor(Date.now() / 1000);

      timestamp = encode(
        mode,
        {
          plain: moment().format(settings.display_timestamp_format),
          numeric
        },
        settings.encoding_radix
      );
    }

    const data = { username, timestamp };

    this.renderCornerLabel(username, timestamp);

    const watermark = renderWatermarkDataURL(
      canvas,
      {
        ...settings,
        color: resolvedColor,
        display_text_font: resolvedTextFont,
        display_username_font: resolvedUsernameFont,
        display_timestamp_font: resolvedTimestampFont
      },
      data
    );

    if (!watermark) {
      this.clearWatermark();
      return;
    }

    const backgroundImage = `url(${watermark})`;
    if (watermarkDiv.style.backgroundImage !== backgroundImage) {
      watermarkDiv.style.backgroundImage = backgroundImage;
    }
  }

  <template>
    <div
      id="watermark-background"
      class={{if @scrollEnabled "scroll" "fixed"}}
      {{didInsert this.setDomElement}}
    />
    <div id="watermark-corner" {{didInsert this.setCornerElement}} />
  </template>
}
