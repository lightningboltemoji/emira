import React from 'react';
import {AbsoluteFill, Sequence, useVideoConfig} from 'remotion';
import {Backdrop} from '../Backdrop';
import type {Shot} from '../camera';
import type {Cut, CutProps} from '../cut';
import {Keys} from '../Keys';
import {Take} from '../Take';
import {type At, resolveAt} from '../timeline';

// The README's video, cut from .github/demo/tapes/readme.tape's take. It opens on the logo; the
// desktop slides over it like a column onto the strip, holds still at one size while the windows
// move, and slides on out to the left, leaving the logo for the loop to start from.

/** Where in the take the cut starts: the logo alone, a second before the desktop slides in. */
const start: At = {marker: 'green', offset: -2.8};
/** Seconds of the logo alone after the take, before the loop. */
const blank = 0.3;
/** How much of the picture the display fills. */
const fill = 0.93;

const shots: Shot[] = [
	{at: start, fill, offscreen: 'right'},
	// In, settling half a second before Green opens.
	{at: {marker: 'green', offset: -1.8}, fill, duration: 0.8, ease: 'emira'},
	// Out, a beat after Clay reaches the front.
	{at: {marker: 'front', offset: 1.8}, fill, offscreen: 'left', duration: 0.8, ease: 'emira'},
];

const ReadmeCut: React.FC<CutProps> = ({timelines}) => {
	const {fps} = useVideoConfig();
	const take = timelines.readme;
	const from = resolveAt(take, start);
	return (
		<AbsoluteFill>
			<Backdrop />
			<Sequence durationInFrames={Math.round((take.duration - from) * fps)}>
				<Take timeline={take} shots={shots} from={start} />
				<Keys timeline={take} shots={shots} from={start} />
			</Sequence>
		</AbsoluteFill>
	);
};

export const readme: Cut = {
	id: 'readme',
	tapes: ['readme'],
	width: 1920,
	height: 1080,
	fps: 60,
	duration: (timelines) => timelines.readme.duration - resolveAt(timelines.readme, start) + blank,
	component: ReadmeCut,
};
