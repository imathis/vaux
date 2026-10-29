// Writes Vaux's page for each kind of Stream Deck: profiles the plugin comes
// with (see Profiles in the manifest). Back, Mute, Live and Clear All along
// the top, as many as fit; your effects below, by place in Vaux's list, so
// the page fills itself.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const devices = [
	// Stream Deck and Stream Deck MK.2.
	{ file: "Vaux", model: "20GBA9901", columns: 5, rows: 3 },
	{ file: "Vaux Mini", model: "20GAI9901", columns: 3, rows: 2 },
	{ file: "Vaux XL", model: "20GAT9901", columns: 8, rows: 4 },
	{ file: "Vaux Plus", model: "20GBD9901", columns: 4, rows: 2 },
	{ file: "Vaux Neo", model: "20GBJ9901", columns: 4, rows: 2 },
];

/** A key's look, as the manifest's state has it; blank takes the plugin's. */
const state = (title = "", alignment = "") => ({
	FFamily: "",
	FSize: "",
	FStyle: "",
	FUnderline: "",
	Image: "",
	Title: title,
	TitleAlignment: alignment,
	TitleColor: "",
	TitleShow: "",
});

const key = (action, name, states, settings = {}) => ({
	Name: name,
	Settings: settings,
	State: 0,
	States: states,
	UUID: `dev.imathis.vaux.${action}`,
});

const top = [
	key("back", "Back", [state()]),
	key("mute", "Mute", [state(), state()]),
	key("live", "Live", [state("Live", "bottom"), state("Live", "bottom")]),
	key("clear", "Clear All", [state("Clear", "bottom")]),
];

const folder = resolve("dev.imathis.vaux.sdPlugin/profiles");
rmSync(folder, { recursive: true, force: true });
mkdirSync(folder, { recursive: true });

for (const device of devices) {
	const actions = {};
	top.slice(0, device.columns).forEach((action, column) => (actions[`${column},0`] = action));
	let place = 1;
	for (let row = 1; row < device.rows; row++) {
		for (let column = 0; column < device.columns; column++) {
			actions[`${column},${row}`] = key("effect", "Effect", [state("", "bottom"), state("", "bottom")], { place: place++ });
		}
	}
	const profile = {
		Actions: actions,
		DeviceModel: device.model,
		InstalledByPluginUUID: "dev.imathis.vaux",
		Name: "Vaux",
		PreconfiguredName: `profiles/${device.file}`,
		Version: "1.0",
	};

	// The same ID every build, from the file's name.
	const hash = createHash("sha1").update(`dev.imathis.vaux/${device.file}`).digest("hex").toUpperCase();
	const id = `${hash.slice(0, 8)}-${hash.slice(8, 12)}-${hash.slice(12, 16)}-${hash.slice(16, 20)}-${hash.slice(20, 32)}`;
	const staging = mkdtempSync(join(tmpdir(), "vaux-profile-"));
	mkdirSync(join(staging, `${id}.sdProfile`));
	writeFileSync(join(staging, `${id}.sdProfile`, "manifest.json"), JSON.stringify(profile, null, "\t"));
	execFileSync("zip", ["-q", "-r", "-X", join(folder, `${device.file}.streamDeckProfile`), `${id}.sdProfile`], { cwd: staging });
	rmSync(staging, { recursive: true });
}

console.log(`Wrote ${devices.length} profiles to ${folder}`);
