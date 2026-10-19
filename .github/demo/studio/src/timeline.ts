import {staticFile} from 'remotion';

// The director's timeline.json (.github/demo/director/Sources/director/Timeline.swift).
// Times are seconds into the take's movie; places are take display points.

export type Rect = {x: number; y: number; width: number; height: number};

export type Timeline = {
	tape: string;
	video: string;
	display: {width: number; height: number};
	scale: number;
	/** When the tape's first step starts. */
	start: number;
	duration: number;
	markers: {name: string; time: number; rect: Rect}[];
	steps: {line: number; command: string; start: number; end: number}[];
	/** Each with the emira command its chord is bound to, if any. */
	keys: {time: number; keys: string; action?: string}[];
};

export const loadTimeline = async (tape: string): Promise<Timeline> => {
	const response = await fetch(staticFile(`${tape}/timeline.json`));
	if (!response.ok) {
		throw new Error(`No take for ${tape}: record it with \`make demo-take TAPE=${tape}\``);
	}
	return response.json();
};

export const takeFile = (timeline: Timeline, file: string) => staticFile(`${timeline.tape}/${file}`);

/** The whole take display, as a rect. */
export const displayRect = (timeline: Timeline): Rect => ({x: 0, y: 0, ...timeline.display});

/**
 * A moment in a take: seconds, a marker's time, or a step's start (or end),
 * by the tape's line number, each with an optional offset in seconds.
 */
export type At =
	number | string | {marker: string; offset?: number} | {line: number; edge?: 'start' | 'end'; offset?: number};

export const marker = (timeline: Timeline, name: string) => {
	const found = timeline.markers.find((m) => m.name === name);
	if (!found) {
		throw new Error(
			`The ${timeline.tape} take has no marker "${name}" (has: ${timeline.markers.map((m) => m.name).join(', ')})`,
		);
	}
	return found;
};

export const resolveAt = (timeline: Timeline, at: At): number => {
	if (typeof at === 'number') {
		return at;
	}
	if (typeof at === 'string') {
		return marker(timeline, at).time;
	}
	if ('marker' in at) {
		return marker(timeline, at.marker).time + (at.offset ?? 0);
	}
	const step = timeline.steps.find((s) => s.line === at.line);
	if (!step) {
		throw new Error(`The ${timeline.tape} take has no step on line ${at.line}`);
	}
	return (at.edge === 'end' ? step.end : step.start) + (at.offset ?? 0);
};
