# Stable Diffusion inference with Python

This directory illustrates how to run Stable Diffusion through MAX Engine.
Specifically, this example extracts StableDiffusion-1.5 from Hugging Face and executes
it via the MAX Engine Python API.

## Quickstart

### Magic instructions

If you are using Magic, you can run the following command:

```sh
magic run run.sh
```

### Pixi instructions

If you are using Pixi, you can run the following command:

```sh
pixi run run.sh
```

### Conda instructions (advanced)

Create a Conda environment, activate that environment, and install the
requirements:

```sh
# Create a Conda environment if you don't have one
conda create -n max-repo
# Update the environment with the environment.yml file
conda env update -n max-repo -f environment.yml --prune
# Run the example
conda run -n max-repo --live-stream bash run.sh
```

### Modular CLI instructions (legacy)

First, install MAX as per the [MAX Engine get started
guide](https://docs.modular.com/engine/get-started/).

Then you can install the package requirements and run this example:

```bash
python3 -m venv venv && source venv/bin/activate
python3 -m pip install --upgrade pip setuptools
python3 -m pip install -r requirements.txt
# Install the MAX Engine Python package
python3 -m pip install --find-links "$(modular config max.path)/wheels" max-engine
# Run the example
bash run.sh
```

## Custom Images

Getting started with your own creative prompts is as simple as:

```sh
./text-to-image.py --prompt "my image description" -o my-image.png
```

But of course, there are some additional settings that can be tweaked for more
fine-grained control over image output. See `./text-to-image.py --help` for
details.

## Files

- `download-model.py`: Downloads [runwayml/stable-diffusion-v1-5
](https://huggingface.co/runwayml/stable-diffusion-v1-5)
and exports it as ONNX.

- `text-to-image.py`: Example program that runs full stable-diffusion pipeline
through MAX Engine in order to generate images from the given prompt.
