import {Config} from '@remotion/cli/config';

// Takes are recorded into .github/demo/takes/<tape>/ by the director.
Config.setPublicDir('../takes');
Config.setVideoImageFormat('jpeg');
Config.setJpegQuality(95);
// Near lossless: encode.sh makes the video people see from this.
Config.setCodec('h264');
Config.setCrf(10);
// Tagged, so whatever decodes it reads the colours it was encoded with.
Config.setColorSpace('bt709');
