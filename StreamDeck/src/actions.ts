import streamDeck, {
	type Action,
	action,
	DeviceType,
	type DidReceiveSettingsEvent,
	type KeyDownEvent,
	type KeyUpEvent,
	type SendToPluginEvent,
	SingletonAction,
	type WillAppearEvent,
	type WillDisappearEvent,
} from "@elgato/streamdeck";
import type { JsonObject, JsonValue } from "@elgato/utils";

import { type Item, vaux } from "./vaux.js";
import { type Slot, slot, views } from "./view.js";

/** A key's picture: Vaux's, off and on; a stand-in; or the plugin's own. */
type Images = Item["image"] | "empty" | "more" | "blank";

/**
 * A key for one of Vaux's items. Down and up go to Vaux as they happen, so a
 * hold works as it does on a shortcut: the effect shows only while held.
 * Lit (its second state) while its item is on.
 */
abstract class VauxKey<T extends JsonObject = JsonObject> extends SingletonAction<T> {
	/** Each key showing's settings, by action ID. */
	#settings = new Map<string, T>();
	/** The item each key down pressed, to let go of the same one. */
	#pressed = new Map<string, string>();
	/** Each key's images as last set: unchanged ones aren't sent again. */
	#images = new Map<string, string>();

	constructor() {
		super();
		vaux.onChange(() => this.refresh());
	}

	/** The item this key presses, if Vaux has it, on `device`. */
	protected abstract item(settings: T, device: string): Item | undefined;

	/** Lit while its item is on. */
	protected async show(action: Action<T>, settings: T): Promise<void> {
		if (action.isKey()) await action.setState(this.item(settings, action.device.id)?.on ? 1 : 0);
	}

	/** Its picture, sent only when it changes. */
	protected async showImages(action: Action<T>, images: Images): Promise<void> {
		if (!action.isKey()) return;
		const key = typeof images === "string" ? images : images ? `${images.off} ${images.on}` : "";
		if (key === (this.#images.get(action.id) ?? "")) return;
		this.#images.set(action.id, key);
		if (images === "empty") await action.setImage("imgs/keys/effect-empty.svg");
		else if (images === "more") await action.setImage("imgs/keys/more.svg");
		else if (images === "blank") await action.setImage("imgs/keys/blank.svg");
		else if (images) {
			await action.setImage(images.off, { state: 0 });
			await action.setImage(images.on, { state: 1 });
		} else await action.setImage();
	}

	protected settings(id: string): T | undefined {
		return this.#settings.get(id);
	}

	override async onWillAppear(ev: WillAppearEvent<T>): Promise<void> {
		this.#settings.set(ev.action.id, ev.payload.settings);
		await this.show(ev.action, ev.payload.settings);
	}

	override onWillDisappear(ev: WillDisappearEvent<T>): void {
		this.#settings.delete(ev.action.id);
		this.#images.delete(ev.action.id);
	}

	override async onDidReceiveSettings(ev: DidReceiveSettingsEvent<T>): Promise<void> {
		this.#settings.set(ev.action.id, ev.payload.settings);
		await this.show(ev.action, ev.payload.settings);
	}

	override async onKeyDown(ev: KeyDownEvent<T>): Promise<void> {
		const item = this.item(ev.payload.settings, ev.action.device.id);
		if (!item) {
			// Vaux isn't running, or doesn't have it (the camera's off).
			await ev.action.showAlert();
			return;
		}
		this.#pressed.set(ev.action.id, item.id);
		vaux.press(item.id);
	}

	override onKeyUp(ev: KeyUpEvent<T>): void {
		const id = this.#pressed.get(ev.action.id);
		if (id === undefined) return;
		this.#pressed.delete(ev.action.id);
		vaux.release(id);
	}

	/** Every key showing, as Vaux now has it. */
	protected async refresh(device?: string): Promise<void> {
		for (const action of this.actions) {
			if (device !== undefined && action.device.id !== device) continue;
			const settings = this.#settings.get(action.id);
			if (settings) await this.show(action, settings);
		}
	}
}

/** Mutes and unmutes the mic. */
@action({ UUID: "dev.imathis.vaux.mute" })
export class Mute extends VauxKey {
	protected item(): Item | undefined {
		return vaux.items.find((item) => item.kind === "mute");
	}
}

/** Opens the Live panel. Blank inside a group on Vaux's page: no use there. */
@action({ UUID: "dev.imathis.vaux.live" })
export class Live extends VauxKey {
	constructor() {
		super();
		views.onChange((device) => void this.refresh(device));
	}

	protected item(): Item | undefined {
		return vaux.items.find((item) => item.kind === "live");
	}

	protected override async show(action: Action<JsonObject>, settings: JsonObject): Promise<void> {
		const blank = inGroup(action.device.id);
		await super.show(action, settings);
		if (!action.isKey()) return;
		await this.showImages(action, blank ? "blank" : undefined);
		await action.setTitle(blank ? "" : undefined);
	}

	override async onKeyDown(ev: KeyDownEvent<JsonObject>): Promise<void> {
		if (!inGroup(ev.action.device.id)) await super.onKeyDown(ev);
	}
}

/** Turns off every effect you turned on. */
@action({ UUID: "dev.imathis.vaux.clear" })
export class ClearAll extends VauxKey {
	protected item(): Item | undefined {
		return vaux.items.find((item) => item.kind === "clearAll");
	}

	/** One look: nothing to light. */
	protected override async show(): Promise<void> {}
}

/**
 * The effect chosen in its settings, and its name, kept for while Vaux is
 * away; or, on Vaux's page, its place there (from 1).
 */
type EffectSettings = {
	effect?: string;
	title?: string;
	place?: number;
};

/**
 * Turns an effect on and off, titled with its name. On Vaux's page, a key
 * shows whatever's in its place there: an effect, a group (pressed, it
 * opens), or More, turning the page.
 */
@action({ UUID: "dev.imathis.vaux.effect" })
export class Effect extends VauxKey<EffectSettings> {
	/** A group or More pressed: it acts as the key comes up. */
	#opening = new Map<string, Slot>();

	constructor() {
		super();
		// The settings, while open, follow effects added and renamed.
		vaux.onChange(() => {
			if (streamDeck.ui.action?.manifestId === this.manifestId) void this.#sendEffects();
		});
		views.onChange((device) => void this.refresh(device));
	}

	/** On Vaux's page: what's in its place, among the page's keys on that device. */
	#slot(settings: EffectSettings, device: string): Slot | undefined {
		if (settings.place === undefined) return undefined;
		const places = [...this.actions].filter((action) => action.device.id === device).map((action) => this.settings(action.id)?.place ?? 0);
		return slot(views.get(device), settings.place, Math.max(settings.place, ...places));
	}

	protected item(settings: EffectSettings, device: string): Item | undefined {
		const slot = this.#slot(settings, device);
		if (slot) return "item" in slot ? slot.item : undefined;
		const item = vaux.item(settings.effect);
		return item?.kind === "effect" ? item : undefined;
	}

	protected override async show(action: Action<EffectSettings>, settings: EffectSettings): Promise<void> {
		await super.show(action, settings);
		if (!action.isKey()) return;
		const slot = this.#slot(settings, action.device.id);
		const item = this.item(settings, action.device.id);
		await this.showImages(action, slot && "empty" in slot ? "empty" : slot && "more" in slot ? "more" : item?.image);
		const title = slot && "more" in slot ? "More" : (item?.title ?? (slot ? "" : (settings.title ?? "")));
		await action.setTitle(wrapped(title));
	}

	override async onWillAppear(ev: WillAppearEvent<EffectSettings>): Promise<void> {
		await super.onWillAppear(ev);
		// Another of the page's keys: the page may now fit more.
		if (ev.payload.settings.place !== undefined) {
			const device = ev.action.device.id;
			pageKeys.set(device, (pageKeys.get(device) ?? new Set()).add(ev.action.id));
			views.changed(device);
		}
	}

	override onWillDisappear(ev: WillDisappearEvent<EffectSettings>): void {
		super.onWillDisappear(ev);
		if (pageKeys.get(ev.action.device.id)?.delete(ev.action.id)) views.changed(ev.action.device.id);
	}


	override async onKeyDown(ev: KeyDownEvent<EffectSettings>): Promise<void> {
		const slot = this.#slot(ev.payload.settings, ev.action.device.id);
		if (slot && ("more" in slot || ("item" in slot && slot.item.kind === "group"))) {
			this.#opening.set(ev.action.id, slot);
			return;
		}
		await super.onKeyDown(ev);
	}

	override onKeyUp(ev: KeyUpEvent<EffectSettings>): void {
		const slot = this.#opening.get(ev.action.id);
		if (!slot) {
			super.onKeyUp(ev);
			return;
		}
		this.#opening.delete(ev.action.id);
		const device = ev.action.device.id;
		const view = views.get(device);
		if ("more" in slot) views.set(device, { ...view, page: view.page + 1 });
		else if ("item" in slot) views.set(device, { group: slot.item.id, page: 0 });
	}

	override async onPropertyInspectorDidAppear(): Promise<void> {
		await this.#sendEffects();
	}

	override async onSendToPlugin(ev: SendToPluginEvent<JsonValue, EffectSettings>): Promise<void> {
		const payload = ev.payload as { request?: string } | null;
		if (payload?.request === "effects") await this.#sendEffects();
	}

	/** The effects to choose from, under their groups, for its settings. */
	async #sendEffects(): Promise<void> {
		await streamDeck.ui.sendToPropertyInspector({
			connected: vaux.connected,
			effects: vaux.effects.map(({ id, title, group }) => ({ id, title, group: vaux.item(group)?.title })),
		});
	}
}

/** A group chosen in its settings, and its name, kept for while Vaux is away. */
type GroupSettings = {
	group?: string;
	title?: string;
};

/**
 * Opens one of your groups on Vaux's page: its effects, always as they are
 * in Vaux. Back comes back here. Lit while one of its effects is on.
 */
@action({ UUID: "dev.imathis.vaux.group" })
export class Group extends VauxKey<GroupSettings> {
	constructor() {
		super();
		vaux.onChange(() => {
			if (streamDeck.ui.action?.manifestId === this.manifestId) void this.#sendGroups();
		});
	}

	protected item(settings: GroupSettings): Item | undefined {
		const item = vaux.item(settings.group);
		return item?.kind === "group" ? item : undefined;
	}

	protected override async show(action: Action<GroupSettings>, settings: GroupSettings): Promise<void> {
		await super.show(action, settings);
		if (!action.isKey()) return;
		const item = this.item(settings);
		await this.showImages(action, item?.image);
		await action.setTitle(wrapped(item?.title ?? settings.title ?? ""));
	}

	override async onKeyDown(ev: KeyDownEvent<GroupSettings>): Promise<void> {
		if (!this.item(ev.payload.settings)) await ev.action.showAlert();
	}

	/** As the key comes up, so letting go doesn't land on the page's key there. */
	override async onKeyUp(ev: KeyUpEvent<GroupSettings>): Promise<void> {
		const item = this.item(ev.payload.settings);
		if (!item) return;
		const device = ev.action.device.id;
		views.set(device, { group: item.id, page: 0 });
		// Already there: in place, without reloading the page.
		if (!onPage(device)) await openPage(ev.action);
	}

	override async onPropertyInspectorDidAppear(): Promise<void> {
		await this.#sendGroups();
	}

	override async onSendToPlugin(ev: SendToPluginEvent<JsonValue, GroupSettings>): Promise<void> {
		const payload = ev.payload as { request?: string } | null;
		if (payload?.request === "groups") await this.#sendGroups();
	}

	/** The groups to choose from, for its settings. */
	async #sendGroups(): Promise<void> {
		await streamDeck.ui.sendToPropertyInspector({
			connected: vaux.connected,
			groups: vaux.groups.map(({ id, title }) => ({ id, title })),
		});
	}
}

/** A name too long for a key on two lines, broken at the space nearest its middle. */
function wrapped(title: string): string {
	if (title.length <= 10 || title.includes("\n")) return title;
	const spaces = [...title.matchAll(/ /g)].map((match) => match.index);
	if (spaces.length === 0) return title;
	const middle = title.length / 2;
	const space = spaces.reduce((best, index) => (Math.abs(index - middle) < Math.abs(best - middle) ? index : best));
	return `${title.slice(0, space)}\n${title.slice(space + 1)}`;
}

/** Vaux's page for each kind of Stream Deck, a profile the plugin comes with. */
const pages: Partial<Record<DeviceType, string>> = {
	[DeviceType.StreamDeck]: "profiles/Vaux",
	[DeviceType.StreamDeckMini]: "profiles/Vaux Mini",
	[DeviceType.StreamDeckXL]: "profiles/Vaux XL",
	[DeviceType.StreamDeckPlus]: "profiles/Vaux Plus",
	[DeviceType.StreamDeckNeo]: "profiles/Vaux Neo",
};

/** The keys of Vaux's page showing on a device, which has one page showing at a time. */
const pageKeys = new Map<string, Set<string>>();

/** Vaux's page is what a device shows. */
function onPage(device: string): boolean {
	return (pageKeys.get(device)?.size ?? 0) > 0;
}

/** Vaux's page shows a group on a device. */
function inGroup(device: string): boolean {
	return onPage(device) && views.get(device).group !== undefined;
}

/** Vaux's page on the key's device; none for a kind it hasn't one for. */
async function openPage(action: Action<JsonObject>): Promise<void> {
	const page = pages[action.device.type];
	if (page) await streamDeck.profiles.switchToProfile(action.device.id, page);
	else if (action.isKey()) await action.showAlert();
}

/**
 * Opens Vaux's page: Mute, Live, Clear All, then your effects and groups.
 * Like a folder, its first key comes back. Switches as the key comes up, so
 * letting go doesn't land on the page's key there.
 */
@action({ UUID: "dev.imathis.vaux.page" })
export class Page extends SingletonAction {
	override async onKeyUp(ev: KeyUpEvent): Promise<void> {
		views.set(ev.action.device.id, { page: 0 });
		await openPage(ev.action);
	}
}

/**
 * Vaux's page's first key: up a level. Out of a group, to everything;
 * from everything, back to the profile you came from.
 */
@action({ UUID: "dev.imathis.vaux.back" })
export class Back extends SingletonAction {
	override async onKeyUp(ev: KeyUpEvent): Promise<void> {
		const device = ev.action.device.id;
		const view = views.get(device);
		views.set(device, { page: 0 });
		if (view.group === undefined) await streamDeck.profiles.switchToProfile(device);
	}
}
