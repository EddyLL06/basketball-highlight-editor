# Shooter preview model notice

The optional desktop quick-label preview includes the official COCO-pretrained
YOLO11n person checkpoint. BHE source licensing does not relicense this model.

- Publisher: Ultralytics, https://github.com/ultralytics/ultralytics
- Model source: https://github.com/ultralytics/assets/releases/download/v8.3.0/yolo11n.pt
- SHA-256: `0ebbc80d4a7680d14987a577cd21342b65ecfd94632bd9a8da63ae6417644ee1`
- Applicable open-source terms: AGPL-3.0; the publisher also offers enterprise
  terms. See https://docs.ultralytics.com/models/yolo11/ and
  https://www.ultralytics.com/license .
- The cloud preview build includes the full AGPL text beside the checkpoint as
  `AGPL-3.0.txt`. Corresponding BHE integration source is the exact Git commit
  recorded in the GitHub Actions run that produced the artifact.

The preview does not include private videos, human labels, player images, or
training data. Images produced by quick-label preparation remain in the local
project folder. This optional model is downloaded and checksum-verified during
the GitHub Actions build; the installed application does not download it.

See also [BHE's model/data policy](MODEL_AND_DATA_LICENSES.md).
