import React from 'react';
import {AbsoluteFill, Img, useVideoConfig} from 'remotion';
import {HEIGHT, WIDTH, frame} from '../../../logo/scene';

/** The wordmark at rest, drawn by .github/logo's own code. */
const wordmark = `data:image/svg+xml;utf8,${encodeURIComponent(frame(0))}`;

/** One colour, with the wordmark in the middle at `logo` of the picture's width. */
export const Backdrop: React.FC<{color?: string; logo?: number}> = ({color = '#0e0f12', logo = 0.34}) => {
	const {width} = useVideoConfig();
	return (
		<AbsoluteFill style={{background: color, justifyContent: 'center', alignItems: 'center'}}>
			<Img src={wordmark} style={{width: width * logo, height: (width * logo * HEIGHT) / WIDTH}} />
		</AbsoluteFill>
	);
};
