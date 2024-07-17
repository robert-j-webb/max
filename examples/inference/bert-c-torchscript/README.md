# TorchScript BERT inference with C

This directory includes scripts used to run simple BERT inference via the MAX
Engine C API to predict the sentiment of the given text.

## Quickstart

For this example, you need a cmake installed on your system and a C compiler.

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

```sh
python3 -m venv .venv && source .venv/bin/activate
python3 -m pip install --upgrade pip setuptools
python3 -m pip install -r requirements.txt
# Install the MAX Engine Python package
python3 -m pip install --find-links "$(modular config max.path)/wheels" max-engine
# Run the MAX Engine example
bash run.sh
```

## Scripts included

Activate the virtual environment created in the previous step to use the following scripts:

- `pre-process.py`: Prepares an example input and saves the pre-processed input
to a local directory, for use use in the `main.c` program. Example:

    ```sh
    python3 pre-process.py --text "Paris is the [MASK] of France."
    ```

- `post-process.py`: Loads the generated output, post-processes it, and outputs
the prediction. Example:

    ```sh
    python3 post-process.py
    ```

## Building the example

This example uses CMake. To build the executable, please use the following
commands:

```sh
export MAX_PKG_DIR=`modular config max.path`
cmake -B build -S .
cmake --build build
```

The executable is called `bert` and will be present in the build directory.

## Usage

- If using the modular CLI install, make sure `bin` directory of `max` package is in `PATH`

- Activate the virtual environment created in the previous step and run the following commands:

```sh
python3 ../common/bert-torchscript/download-model.py
python3 pre-process.py --text "Your text"
./build/bert ../../models/bert.torchscript
python3 post-process.py
```
