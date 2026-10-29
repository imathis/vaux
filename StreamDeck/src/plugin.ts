import streamDeck from "@elgato/streamdeck";

import { Back, ClearAll, Effect, Group, Live, Mute, Page } from "./actions.js";
import { vaux } from "./vaux.js";

streamDeck.actions.registerAction(new Mute());
streamDeck.actions.registerAction(new Effect());
streamDeck.actions.registerAction(new Live());
streamDeck.actions.registerAction(new ClearAll());
streamDeck.actions.registerAction(new Group());
streamDeck.actions.registerAction(new Page());
streamDeck.actions.registerAction(new Back());

vaux.start();
streamDeck.connect();
