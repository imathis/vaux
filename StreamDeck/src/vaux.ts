import { existsSync } from "node:fs";
import { createConnection, type Socket } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";

/** Something on a key: Mute, Live, an effect, a group, or Clear All, and whether it's on. */
export type Item = {
	id: string;
	title: string;
	kind: "mute" | "live" | "effect" | "group" | "clearAll";
	on: boolean;
	/** An effect's or group's key, off and on, in its icon and color: PNG data URLs. */
	image?: { off: string; on: string };
	/** An effect's group, by its ID. */
	group?: string;
};

/**
 * Vaux's control sockets (see ControlServer in Vaux): the installed Vaux's
 * first, then Vaux Dev's.
 */
const sockets = process.env.VAUX_SOCKET
	? // Tests stand in for Vaux.
		[process.env.VAUX_SOCKET]
	: ["dev.imathis.vaux", "dev.imathis.vaux.debug"].map((id) => join(homedir(), "Library", "Application Support", id, "control.sock"));

/**
 * The connection to Vaux: what there is to put on keys and what's on, kept
 * up to date as Vaux sends it, and keys pressed and let go. Reconnects as
 * Vaux comes and goes.
 */
class Vaux {
	/** Empty while Vaux isn't there. */
	items: Item[] = [];
	connected = false;

	#socket?: Socket;
	#buffer = "";
	#listeners = new Set<() => void>();

	start(): void {
		this.#connect(0);
	}

	/** Called whenever what there is, or what's on, changes. */
	onChange(listener: () => void): void {
		this.#listeners.add(listener);
	}

	press(id: string): void {
		this.#send({ press: id });
	}

	release(id: string): void {
		this.#send({ release: id });
	}

	item(id: string | undefined): Item | undefined {
		return this.items.find((item) => item.id === id);
	}

	/** Your effects, in the order Vaux lists them. */
	get effects(): Item[] {
		return this.items.filter((item) => item.kind === "effect");
	}

	/** Your groups, in their order. */
	get groups(): Item[] {
		return this.items.filter((item) => item.kind === "group");
	}

	/** Tries each socket in turn; when none answers, again in a moment. */
	#connect(index: number): void {
		const path = sockets.slice(index).find((path) => existsSync(path));
		if (!path) {
			setTimeout(() => this.#connect(0), 2000);
			return;
		}
		const next = sockets.indexOf(path) + 1;
		const socket = createConnection(path);
		socket.setEncoding("utf8");
		socket.on("connect", () => {
			this.#socket = socket;
			this.connected = true;
		});
		socket.on("data", (chunk: string) => this.#receive(chunk));
		// Followed by "close".
		socket.on("error", () => {});
		socket.on("close", () => {
			const wasConnected = this.#socket === socket;
			this.#socket = undefined;
			this.#buffer = "";
			if (wasConnected) {
				this.connected = false;
				this.items = [];
				this.#changed();
				setTimeout(() => this.#connect(0), 1000);
			} else {
				// Never answered (a Vaux that's quit leaves its socket): the next.
				this.#connect(next);
			}
		});
	}

	#receive(chunk: string): void {
		this.#buffer += chunk;
		let newline: number;
		while ((newline = this.#buffer.indexOf("\n")) >= 0) {
			const line = this.#buffer.slice(0, newline);
			this.#buffer = this.#buffer.slice(newline + 1);
			try {
				const message = JSON.parse(line) as { items?: Item[] };
				if (Array.isArray(message.items)) {
					this.items = message.items;
					this.#changed();
				}
			} catch {
				// Not a message.
			}
		}
	}

	#send(message: object): void {
		this.#socket?.write(`${JSON.stringify(message)}\n`);
	}

	#changed(): void {
		for (const listener of this.#listeners) listener();
	}
}

export const vaux = new Vaux();
