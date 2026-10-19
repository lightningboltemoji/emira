import React, {useId, useMemo} from 'react';
import {AbsoluteFill, OffthreadVideo, getRemotionEnvironment, useCurrentFrame, useVideoConfig} from 'remotion';
import {type CameraState, type Shot, cameraAt, cameraTransform, resolveShots, travel} from './camera';
import {type At, type Timeline, displayRect, resolveAt, takeFile} from './timeline';

/** The display's corner radius, in its points: a screen floating over the backdrop. */
const radius = 14;

/**
 * The take's display, where the camera sees it, from take time `from` on. Fast moves are blurred
 * across `shutter` of a frame: a pan along its length, anything else by averaging several instants.
 */
export const Take: React.FC<{timeline: Timeline; shots: Shot[]; from?: At; shutter?: number}> = ({
	timeline,
	shots,
	from = 0,
	shutter = 0.5,
}) => {
	const frame = useCurrentFrame();
	const {fps, width, height} = useVideoConfig();
	const start = resolveAt(timeline, from);
	const resolved = useMemo(() => resolveShots(timeline, shots, {width, height}), [timeline, shots, width, height]);
	const filter = `pan-${useId().replace(/:/g, '')}`;
	const t = start + frame / fps;
	const open = shutter / fps;
	const now = cameraAt(resolved, t);
	const before = cameraAt(resolved, t - open / 2);
	const after = cameraAt(resolved, t + open / 2);
	const moved = getRemotionEnvironment().isRendering ? travel(before, after, displayRect(timeline)) : 0;
	const trimBefore = Math.round(start * fps);
	if (moved < 1.5) {
		return (
			<AbsoluteFill>
				<Shadow timeline={timeline} state={now} />
				<Screen timeline={timeline} state={now} trimBefore={trimBefore} />
			</AbsoluteFill>
		);
	}
	if (pans(before, after)) {
		// A box blur the pan's length, as a Gaussian of the same spread. In sRGB, so a flat colour comes
		// out exactly as it went in, where averaging faint copies would round it off.
		const spread = (d: number) => (Math.abs(d) * now.scale) / Math.sqrt(12);
		return (
			<AbsoluteFill>
				<svg style={{position: 'absolute', width: 0, height: 0}}>
					<filter id={filter} colorInterpolationFilters="sRGB">
						<feGaussianBlur stdDeviation={`${spread(after.x - before.x)} ${spread(after.y - before.y)}`} />
					</filter>
				</svg>
				<AbsoluteFill style={{filter: `url(#${filter})`}}>
					<Shadow timeline={timeline} state={now} />
					<Screen timeline={timeline} state={now} trimBefore={trimBefore} />
				</AbsoluteFill>
			</AbsoluteFill>
		);
	}
	const samples = Math.min(24, Math.ceil(moved / 1.5));
	const states = Array.from({length: samples}, (_, i) => cameraAt(resolved, t - open / 2 + (open * (i + 0.5)) / samples));
	return (
		<AbsoluteFill>
			{/* Soft already, so drawn once, where the camera is mid-shutter. */}
			<Shadow timeline={timeline} state={now} />
			<AbsoluteFill style={{isolation: 'isolate'}}>
				{states.map((state, i) => (
					<Screen
						key={i}
						timeline={timeline}
						state={state}
						trimBefore={trimBefore}
						style={{opacity: 1 / samples, mixBlendMode: 'plus-lighter'}}
					/>
				))}
			</AbsoluteFill>
		</AbsoluteFill>
	);
};

/** Whether the camera only moves sideways between `a` and `b`. */
const pans = (a: CameraState, b: CameraState) =>
	Math.abs(a.scale / b.scale - 1) < 1e-4 && a.rx === b.rx && a.ry === b.ry && a.rz === b.rz;

/** A display-sized box where the camera sees it. */
const Placed: React.FC<{
	timeline: Timeline;
	state: CameraState;
	style?: React.CSSProperties;
	children: React.ReactNode;
}> = ({timeline, state, style, children}) => {
	const {width, height} = useVideoConfig();
	return (
		<div
			style={{
				position: 'absolute',
				left: 0,
				top: 0,
				width: timeline.display.width,
				height: timeline.display.height,
				transformOrigin: '0 0',
				transform: cameraTransform(state, {width, height}),
				...style,
			}}
		>
			{children}
		</div>
	);
};

const Shadow: React.FC<{timeline: Timeline; state: CameraState}> = ({timeline, state}) => (
	<Placed timeline={timeline} state={state}>
		<div
			style={{
				position: 'absolute',
				inset: 0,
				borderRadius: radius,
				background: 'black',
				opacity: 0.6,
				filter: 'blur(48px)',
				transform: 'translateY(36px)',
			}}
		/>
		<div
			style={{
				position: 'absolute',
				inset: 0,
				borderRadius: radius,
				background: 'black',
				opacity: 0.35,
				filter: 'blur(8px)',
				transform: 'translateY(4px)',
			}}
		/>
	</Placed>
);

const Screen: React.FC<{
	timeline: Timeline;
	state: CameraState;
	trimBefore: number;
	style?: React.CSSProperties;
}> = ({timeline, state, trimBefore, style}) => (
	<Placed timeline={timeline} state={state} style={style}>
		<div style={{position: 'absolute', inset: 0, borderRadius: radius, overflow: 'hidden', background: 'black'}}>
			<OffthreadVideo
				src={takeFile(timeline, timeline.video)}
				trimBefore={trimBefore}
				muted
				style={{width: '100%', height: '100%'}}
			/>
		</div>
		{/* A hairline rim, which keeps the display's dark edges apart from the dark backdrop. */}
		<div
			style={{
				position: 'absolute',
				inset: 0,
				borderRadius: radius,
				boxShadow: 'inset 0 0 0 1px rgba(255,255,255,0.14)',
				pointerEvents: 'none',
			}}
		/>
	</Placed>
);
