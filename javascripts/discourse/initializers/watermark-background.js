import { withPluginApi } from "discourse/lib/plugin-api";
import WatermarkBackground from "../components/watermark-background";

export default {
  name: "watermark-background-widget",

  initialize() {
    withPluginApi("1.13.0", (api) => {
      api.renderInOutlet("above-site-header", WatermarkBackground);
    });
  },
};
