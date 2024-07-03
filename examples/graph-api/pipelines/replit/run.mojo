# ===----------------------------------------------------------------------=== #
# Copyright (c) 2024, Modular Inc. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ===----------------------------------------------------------------------=== #
from pathlib import cwd, Path
import sys

from max._driver import (
    Device,
    AnyTensor,
    Tensor,
    cuda_device,
    cpu_device,
    ExecutableGraph,
)
from utils import StaticTuple
from max.tensor import TensorSpec

from .model.replit import Replit
from .weights.replit_checkpoint import ReplitCheckpoint
from .weights.hyperparams import get_default

from ..configs.registry import ConfigRegistryDict
from ..configs.parse_args import (
    OptionTypeEnum,
    OptionValue,
    parse_args,
    register_pipeline_configs,
)
from ..samplers.token_sampler import TokenSampler
from ..samplers.weighted_sampler import WeightedSampler
from ..tokenizer import AutoTokenizer
from ..llama3.metrics import Metrics

# TODO: Expand this back out to 512 once MSDK-305 is fully resolved.
alias DEFAULT_MAX_SEQ_LEN = 33


@value
struct Config:
    var config: Dict[String, OptionValue]

    def __init__(inout self):
        args = ConfigRegistryDict()
        args["converted_weights_path"] = OptionTypeEnum.PATH
        args["prompt"] = OptionTypeEnum.STRING
        args["max_length"] = OptionTypeEnum.INT
        args["max_new_tokens"] = OptionTypeEnum.INT
        args["experimental-use-gpu"] = OptionTypeEnum.BOOL
        args["dtype"] = OptionTypeEnum.STRING

        default_configs = Dict[String, OptionValue]()
        default_configs["converted_weights_path"] = Path("")
        default_configs["prompt"] = str('def hello():\n  print("hello world")')
        default_configs["experimental-use-gpu"] = False
        default_configs["dtype"] = str("float32")

        self.config = register_pipeline_configs(
            args,
            parse_args(),
            default_configs,
        )

    def __contains__(self, key: String):
        return key in self.config

    fn get(inout self, key: String) raises -> OptionValue:
        """Returns an option value for `key` in the underlying config.

        Args:
            key: Key for the underlying config option.

        Returns:
            An OptionValue.

        Raises:
            An error for invalid key.
        """
        return self.config[key]

    fn set(inout self, key: String, val: OptionValue):
        """Sets a new value for a given config key. This will overwrite the old
        value if the key is already present.

        Args:
            key: A string based key for the underlying config option.
            val: A new value for a key that already exist.
        """
        self.config[key] = val


struct ReplitPipeline[dtype: DType]:
    """Code completion model based on Replit.

    Parameters:
        dtype: The DType of the weights and inputs to this model.
    """

    var _replit: Replit[ReplitCheckpoint, dtype]
    """Class that builds the Replit model graph."""

    var _device: Device
    """Chosen device for execution."""

    var _run_on_gpu: Bool
    """Device chosen is gpu or not."""

    var _cpu_device: Device
    """An instance of cpu device. If chosen device is cpu this will
    be a copy of chosen device."""

    var _executable_graph: ExecutableGraph
    """Graph compiled, initialized and ready for execution."""

    var _tokenizer: AutoTokenizer
    """Tokenizer for encoding/decoding the inputs and outputs."""

    # Token generation settings.
    var _max_length: Optional[Int]
    var _max_new_tokens: Optional[Int]

    # Attributes updated during generation.
    var _initial_prompt: String
    """Initial prompt user passed to `ReplitPipeline.reset()` method."""

    var _max_seq_len: Int
    """Maximum sequence length that will be generated by next_token(). This
    value includes the length of the inital prompt."""

    var _k_cache: AnyTensor
    """Cache containing past computed attention keys."""

    var _v_cache: AnyTensor
    """Cache containing past computed attention values."""

    var _next_token_tensor: AnyTensor
    """ID of the last token generated by `ReplitPipeline.next_token()`, which
    will be used as the next input to the model."""

    var _cur_seq_len: Int
    """Length of the current sequence (including prompt)."""

    var _is_end_of_text: Bool
    """Whether text generation has reached an end-of-text token."""

    def __init__(
        inout self,
        checkpoint_file: Path,
        use_gpu: Bool = False,
        max_length: Optional[Int] = None,
        max_new_tokens: Optional[Int] = None,
    ):
        """Builds and compiles a Replit model to get ready for execution."""
        # Generate a graph that does a single forward pass of the replit model.
        print("Building model...")
        self._replit = Replit[ReplitCheckpoint, dtype](get_default())
        g = self._replit.build_graph(
            "replit",
            ReplitCheckpoint(checkpoint_file),
            with_attention_mask=True,
            use_cache=True,
        )

        self._device = cuda_device() if use_gpu else cpu_device()
        self._run_on_gpu = use_gpu
        self._cpu_device = cpu_device() if use_gpu else self._device

        # Compile and load the graph, which generates the MLIR and runs
        # optimization passes on it.
        print("Compiling...")
        compiled_graph = self._device.compile(g)
        self._executable_graph = self._device.load(compiled_graph)

        # Set up tokenizer.
        var hf_model_name = "replit/replit-code-v1_5-3b"
        self._tokenizer = AutoTokenizer(hf_model_name)

        # Set default token generation options.
        self._max_length = None
        if max_length:
            self._max_length = max_length.value()
        self._max_new_tokens = None
        if max_new_tokens:
            self._max_new_tokens = max_new_tokens.value()

        # Initialize token generation attributes.
        self._initial_prompt = ""
        self._max_seq_len = 0
        kv_cache = self._replit.create_empty_cache(self._device)
        self._k_cache = kv_cache[0].take()
        self._v_cache = kv_cache[1].take()
        self._next_token_tensor = AnyTensor()
        self._cur_seq_len = 0
        self._is_end_of_text = True

    def _get_max_tokens(self, prompt_len: Int) -> Int:
        """Returns the max sequence length to generate (including the prompt).
        """
        if self._max_length:
            if self._max_new_tokens:
                return min(
                    self._max_new_tokens.value() + prompt_len,
                    self._max_length.value(),
                )
            else:
                return self._max_length.value()
        elif self._max_new_tokens:
            return self._max_new_tokens.value() + prompt_len
        else:
            return DEFAULT_MAX_SEQ_LEN

    def reset(inout self, prompt: String) -> Int:
        """Resets the prompt and model state."""
        self._initial_prompt = prompt
        self._max_seq_len = self._get_max_tokens(len(prompt))
        kv_cache = self._replit.create_empty_cache(self._device)
        self._k_cache = kv_cache[0].take()
        self._v_cache = kv_cache[1].take()

        encoded_prompt = self._tokenizer.encode(List(prompt))
        next_token_tensor = Tensor[DType.int64, 2]((1, len(encoded_prompt)))
        for i in range(len(encoded_prompt)):
            next_token_tensor[0, i] = encoded_prompt[i]
        self._set_next_token_tensor(next_token_tensor)

        self._cur_seq_len = len(encoded_prompt)
        self._max_seq_len = self._get_max_tokens(self._cur_seq_len)
        self._is_end_of_text = False
        return encoded_prompt.size

    def next_token(inout self) -> Optional[String]:
        """Generates the next token, or None if the end has been reached."""
        return self.next_token(WeightedSampler(0))

    def _set_next_token_tensor(inout self, owned next_token_tensor: AnyTensor):
        """Set the given value as next token tensor. If the chosen
        device is gpu, value will be copied over to the device."""

        if self._run_on_gpu:
            next_token_tensor = next_token_tensor.to_device_tensor().copy_to(
                self._device
            )

        self._next_token_tensor = next_token_tensor^

    def _get_attention_mask(self) -> AnyTensor:
        """Generates attention mask for current input sequence.
        Result is placed on the chosen device.
        """

        attention_mask_tensor = Tensor[DType.bool, 2]((1, self._cur_seq_len))
        for i in range(self._cur_seq_len):
            attention_mask_tensor[0, i] = True

        if self._run_on_gpu:
            return attention_mask_tensor.to_device_tensor().copy_to(
                self._device
            )

        return attention_mask_tensor

    def next_token[
        Sampler: TokenSampler
    ](inout self, sampler: Sampler) -> Optional[String]:
        """Generates the next token, or None if the end has been reached."""
        if self._is_end_of_text or self._max_seq_len - self._cur_seq_len <= 0:
            return None

        results = self._device.execute(
            self._executable_graph,
            self._next_token_tensor.take(),
            self._get_attention_mask(),
            self._k_cache.take(),
            self._v_cache.take(),
        )

        output = results[0].take()
        self._k_cache = results[1].take()
        self._v_cache = results[2].take()

        logits = output.to_device_tensor()
        if self._run_on_gpu:
            logits = logits.copy_to(self._cpu_device)
        var token: Int64 = sampler._sample(
            logits.to_tensor[dtype, 2]()
        ).selected
        if self._tokenizer.is_end_of_text(token):
            self._is_end_of_text = True
            return None
        self._cur_seq_len += 1

        next_token_tensor = Tensor[DType.int64, 2]((1, 1))
        next_token_tensor[0, 0] = token
        self._set_next_token_tensor(next_token_tensor)

        return self._tokenizer.decode(token)


def dispatch[dtype: DType](config: Config):
    """Dispatches token generation for a model."""
    metrics = Metrics()
    metrics.begin_timing_startup()

    # Set up the Replit model prepare it for token generation.
    var max_length: Optional[Int] = None
    if "max_length" in config:
        max_length = config.get("max_length")[Int]
    var max_new_tokens: Optional[Int] = None
    if "max_new_tokens" in config:
        max_new_tokens = config.get("max_new_tokens")[Int]
    replit = ReplitPipeline[dtype](
        config.get("converted_weights_path")[Path],
        use_gpu=config.get("experimental-use-gpu")[Bool],
        max_length=max_length,
        max_new_tokens=max_new_tokens,
    )
    metrics.end_timing_startup()

    input_string = config.get("prompt")[String]
    print("Running on input:", input_string)

    # Make sure newlines are properly encoded in the prompt.
    prompt = input_string.replace("\\n", "\n")

    # Run code generation.
    metrics.begin_timing_prompt()
    tokens_in_prompt = replit.reset(prompt)
    sampler = WeightedSampler(0.5)

    metrics.set_tokens_in_prompt(tokens_in_prompt)

    print("Output:")
    metrics.begin_timing_generation()
    while True:
        s = replit.next_token(sampler)
        if not s:
            break
        metrics.new_token()
        print(s.value(), end="")
    metrics.end_timing()
    print()
    metrics.print()


def replit_run():
    config = Config()

    # Finalize parsed arguments.
    dtype = DType.float32

    raw_type = config.get("dtype")[String]
    if not sys.info.is_x86() and raw_type == "bfloat16":
        raise "bfloat16 is not supported for ARM architectures."
    if raw_type == "float32":
        dtype = DType.float32
    elif raw_type == "bfloat16":
        dtype = DType.bfloat16
    else:
        raise "dtype must be 'bfloat16' or 'float32', got" + raw_type

    converted_weights_path = config.get("converted_weights_path")[Path]
    if len(str(converted_weights_path)) == 0:
        if dtype == DType.float32:
            converted_weights_path = cwd().joinpath(
                ".cache/replit/converted_float32"
            )
        else:  # DType.bfloat16
            converted_weights_path = cwd().joinpath(
                ".cache/replit/converted_bfloat16"
            )
        if not converted_weights_path.exists():
            raise (
                "Unable to find checkpoint at "
                + str(converted_weights_path)
                + ". Please run: setup.sh "
                + raw_type
            )
        print("Using checkpoint at", converted_weights_path)
        config.set("converted_weights_path", converted_weights_path)

    @parameter
    if not is_x86():
        dispatch[DType.float32](config)
    else:
        if dtype == DType.bfloat16:
            dispatch[DType.bfloat16](config)
        else:
            dispatch[DType.float32](config)
