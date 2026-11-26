import { mount } from "svelte";
import "./app.css";
import "./components/ui/ui.css";
import { installNookTips } from "./components/ui/tip";
import App from "./App.svelte";

installNookTips();

const app = mount(App, { target: document.getElementById("app")! });

export default app;
