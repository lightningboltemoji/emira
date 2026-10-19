import React, {useMemo} from 'react';
import {AbsoluteFill, interpolate, useCurrentFrame, useVideoConfig} from 'remotion';
import {type Shot, cameraAt, onScreen, resolveShots} from './camera';
import {type At, type Timeline, displayRect, resolveAt} from './timeline';

/** Keys as emira's config names them, as their caps print them. */
const symbols: Record<string, string> = {
	cmd: '⌘',
	shift: '⇧',
	alt: '⌥',
	option: '⌥',
	ctrl: '⌃',
	control: '⌃',
	fn: 'fn',
	globe: 'fn',
	return: 'return',
	enter: 'return',
	escape: 'esc',
	esc: 'esc',
	tab: 'tab',
	delete: 'delete',
	space: 'space',
	up: '↑',
	down: '↓',
	left: '←',
	right: '→',
	minus: '-',
	equal: '=',
	leftbracket: '[',
	rightbracket: ']',
	semicolon: ';',
	quote: "'",
	comma: ',',
	period: '.',
	slash: '/',
	backslash: '\\',
	grave: '`',
};

/**
 * The chords pressed in the take, as keycaps along the bottom of the
 * picture, over the display that `shots` film, each over the emira command
 * it runs. Keys pressed alone, like return, aren't chords, so aren't shown.
 */
export const Keys: React.FC<{timeline: Timeline; shots: Shot[]; from?: At; hold?: number}> = ({
	timeline,
	shots,
	from = 0,
	hold = 1.1,
}) => {
	const frame = useCurrentFrame();
	const {fps, width, height} = useVideoConfig();
	const resolved = useMemo(() => resolveShots(timeline, shots, {width, height}), [timeline, shots, width, height]);
	const t = resolveAt(timeline, from) + frame / fps;
	const pressed = timeline.keys.filter((k) => k.keys.includes('+') && k.time <= t);
	const shown = pressed.at(-1);
	if (!shown || t >= shown.time + hold) {
		return null;
	}
	// A chord pressed again while it's still up stays up, and only pops for each press.
	let first = shown;
	for (const k of pressed.slice(0, -1).reverse()) {
		if (k.keys !== shown.keys || first.time - k.time >= hold) {
			break;
		}
		first = k;
	}
	const opacity = interpolate(t, [first.time, first.time + 0.1, shown.time + hold - 0.25, shown.time + hold], [0, 1, 1, 0], {
		extrapolateLeft: 'clamp',
		extrapolateRight: 'clamp',
	});
	const scale = interpolate(t - shown.time, [0, 0.14], [0.92, 1], {extrapolateRight: 'clamp'});
	const caps = shown.keys.split('+').map((part) => symbols[part] ?? part.toUpperCase());
	const size = height / 24;
	// Half on the display and half on the backdrop, keycaps lose their
	// contrast on one or the other, so they rise to stay on the display.
	const displayBottom = Math.min(
		...Array.from({length: 12}, (_, i) => {
			const rect = onScreen(cameraAt(resolved, shown.time + (hold * i) / 11), displayRect(timeline), {width, height});
			return rect.y + rect.height;
		}),
	);
	const bottom = Math.max(height * 0.07, height - displayBottom + height * 0.04);
	return (
		<AbsoluteFill style={{justifyContent: 'flex-end', alignItems: 'center', paddingBottom: bottom}}>
			<div
				style={{
					display: 'flex',
					flexDirection: 'column',
					alignItems: 'center',
					gap: size * 0.4,
					opacity,
					transform: `scale(${scale})`,
				}}
			>
				<div style={{display: 'flex', gap: size * 0.3}}>
					{caps.map((cap, i) => (
						<div
							key={i}
							style={{
								minWidth: size * 1.7,
								height: size * 1.7,
								padding: `0 ${size * 0.45}px`,
								borderRadius: size * 0.42,
								display: 'flex',
								alignItems: 'center',
								justifyContent: 'center',
								fontFamily: 'system-ui',
								fontWeight: 500,
								fontSize: cap.length > 1 ? size * 0.62 : size * 0.85,
								color: 'rgba(255,255,255,0.96)',
								background: 'linear-gradient(180deg, rgba(58,58,64,0.72), rgba(28,28,32,0.78))',
								border: '1px solid rgba(255,255,255,0.16)',
								boxShadow: '0 12px 34px rgba(0,0,0,0.4), inset 0 1px 0 rgba(255,255,255,0.18)',
								backdropFilter: 'blur(24px) saturate(1.4)',
							}}
						>
							{cap}
						</div>
					))}
				</div>
				{shown.action ? (
					<div
						style={{
							padding: `${size * 0.22}px ${size * 0.5}px`,
							borderRadius: size,
							fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
							fontSize: size * 0.52,
							color: 'rgba(255,255,255,0.9)',
							background: 'rgba(24,24,28,0.62)',
							border: '1px solid rgba(255,255,255,0.12)',
							backdropFilter: 'blur(24px) saturate(1.4)',
						}}
					>
						{shown.action}
					</div>
				) : null}
			</div>
		</AbsoluteFill>
	);
};
