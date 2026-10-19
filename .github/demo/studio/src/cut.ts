import type React from 'react';
import type {Timeline} from './timeline';

export type CutProps = {timelines: Record<string, Timeline>};

/** A video cut from takes: which tapes' takes it uses, and how long it runs given them. */
export type Cut = {
	id: string;
	tapes: string[];
	width: number;
	height: number;
	fps: number;
	duration: (timelines: Record<string, Timeline>) => number;
	component: React.FC<CutProps>;
};
