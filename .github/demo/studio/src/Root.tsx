import React from 'react';
import {Composition} from 'remotion';
import type {CutProps} from './cut';
import {cuts} from './cuts';
import {loadTimeline} from './timeline';

export const Root: React.FC = () => (
	<>
		{cuts.map((cut) => (
			<Composition
				key={cut.id}
				id={cut.id}
				component={cut.component}
				width={cut.width}
				height={cut.height}
				fps={cut.fps}
				durationInFrames={1}
				defaultProps={{timelines: {}}}
				calculateMetadata={async () => {
					const timelines = Object.fromEntries(
						await Promise.all(cut.tapes.map(async (tape) => [tape, await loadTimeline(tape)] as const)),
					);
					return {durationInFrames: Math.ceil(cut.duration(timelines) * cut.fps), props: {timelines}};
				}}
			/>
		))}
	</>
);
