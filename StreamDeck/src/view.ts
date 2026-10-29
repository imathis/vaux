import { type Item, vaux } from "./vaux.js";

/**
 * What Vaux's page shows on a device: everything (your effects in no
 * group, and your groups, as listed), or one group's effects; and which
 * page of them, when there are more than keys.
 */
export type View = {
	group?: string;
	page: number;
};

/** What one of the page's keys shows. */
export type Slot = { item: Item } | { more: true } | { empty: true };

class Views {
	#views = new Map<string, View>();
	#listeners = new Set<(device: string) => void>();

	get(device: string): View {
		return this.#views.get(device) ?? { page: 0 };
	}

	set(device: string, view: View): void {
		this.#views.set(device, view);
		this.changed(device);
	}

	/** Its keys redrawn: what the page shows hasn't changed, but where it shows has. */
	changed(device: string): void {
		for (const listener of this.#listeners) listener(device);
	}

	/** Called whenever a device's page shows something else. */
	onChange(listener: (device: string) => void): void {
		this.#listeners.add(listener);
	}
}

export const views = new Views();

/**
 * The items in a view, in Vaux's order: a group's effects; or effects in
 * no group, and groups, mixed as they're listed.
 */
export function items(view: View): Item[] {
	if (view.group !== undefined) return vaux.effects.filter((item) => item.group === view.group);
	return vaux.items.filter((item) => item.kind === "group" || (item.kind === "effect" && item.group === undefined));
}

/**
 * The key at `place` (from 1) of `count` on the page. More than fit: the
 * last key turns the page, round and round.
 */
export function slot(view: View, place: number, count: number): Slot {
	const all = items(view);
	if (all.length <= count) {
		const item = all[place - 1];
		return item ? { item } : { empty: true };
	}
	if (place === count) return { more: true };
	const perPage = count - 1;
	const pages = Math.ceil(all.length / perPage);
	const page = ((view.page % pages) + pages) % pages;
	const item = all[page * perPage + place - 1];
	return item ? { item } : { empty: true };
}
