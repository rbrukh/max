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
"""A tokenizer that leverages the Hugging Face transformers library."""

from python import Python
from random import randint
from math import ceildiv

from tensor import Tensor, TensorShape


trait Tokenizer:
    fn is_end_of_text(self, val: Int64) raises -> Bool:
        ...

    fn encode(self, input_string: List[String]) raises -> Tensor[DType.int64]:
        ...

    fn decode(self, output_tokens: Tensor[DType.int64]) raises -> List[String]:
        ...


struct AutoTokenizer(Tokenizer):
    """Wrapper around generic tokenizers loaded from the huggingface
    transformers library.

    WARN: There are some extra copies that happen in the naive form of this
    tokenizer, specifically when converting python list -> numpy tensor -> MAX Tensor.
    """

    var _transformers_module: PythonObject
    var _numpy_module: PythonObject
    var _tokenizer_handle: PythonObject
    var _py_builtins_handle: PythonObject

    def __init__(inout self, hf_tokenizer_name: String):
        self._transformers_module = Python.import_module("transformers")
        self._numpy_module = Python.import_module("numpy")
        self._tokenizer_handle = (
            self._transformers_module.AutoTokenizer.from_pretrained(
                hf_tokenizer_name
            )
        )
        self._py_builtins_handle = Python.import_module("builtins")

    @always_inline
    @staticmethod
    fn _numpy_data_pointer[
        type: DType
    ](numpy_array: PythonObject) raises -> DTypePointer[type]:
        return DTypePointer[type](
            __mlir_op.`pop.index_to_pointer`[
                _type = __mlir_type[`!kgen.pointer<scalar<`, type.value, `>>`]
            ](
                Scalar[DType.index](
                    numpy_array.__array_interface__["data"][0].__index__()
                ).value
            )
        )

    @always_inline
    @staticmethod
    fn _memcpy_to_numpy(array: PythonObject, tensor: Tensor) raises:
        var dst = AutoTokenizer._numpy_data_pointer[tensor.type](array)
        var src = tensor._ptr
        var length = tensor.num_elements()
        memcpy(dst, src, length)

    @always_inline
    @staticmethod
    fn _memcpy_from_numpy(array: PythonObject, tensor: Tensor) raises:
        var src = AutoTokenizer._numpy_data_pointer[tensor.type](array)
        var dst = tensor._ptr
        var length = tensor.num_elements()
        memcpy(dst, src, length)

    @staticmethod
    @always_inline
    fn _numpy_to_tensor[
        type: DType
    ](array: PythonObject) raises -> Tensor[type]:
        var shape = List[Int]()
        var array_shape = array.shape
        for dim in array_shape:
            shape.append(dim.__index__())
        var out = Tensor[type](shape)
        AutoTokenizer._memcpy_from_numpy(array, out)
        return out^

    @always_inline
    fn _list_of_string_to_py_list(
        self, string_list: List[String]
    ) raises -> PythonObject:
        var input_string_py = self._py_builtins_handle.list()
        for i in range(len(string_list)):
            input_string_py.append(string_list[i])

        return input_string_py

    @always_inline
    fn _shape_to_python_list(self, shape: TensorShape) raises -> PythonObject:
        var python_list = self._py_builtins_handle.list()
        for i in range(shape.rank()):
            python_list.append(shape[i])
        return python_list^

    @always_inline
    fn _get_np_dtype[type: DType](self) raises -> PythonObject:
        @parameter
        if type.is_float32():
            return self._numpy_module.float32
        elif type.is_int32():
            return self._numpy_module.int32
        elif type.is_int64():
            return self._numpy_module.int64
        elif type.is_uint8():
            return self._numpy_module.uint8

        raise Error("Unknown datatype")

    @always_inline
    fn _tensor_to_numpy[
        type: DType
    ](self, tensor: Tensor[type]) raises -> PythonObject:
        var shape = self._shape_to_python_list(tensor.shape())
        var tensor_as_numpy = self._numpy_module.zeros(
            shape, self._get_np_dtype[type]()
        )
        _ = shape^
        self._memcpy_to_numpy(tensor_as_numpy, tensor)
        return tensor_as_numpy^

    fn is_end_of_text(self, val: Int64) raises -> Bool:
        return val == int(self._tokenizer_handle.eos_token_id)

    fn encode(self, input_string: List[String]) raises -> Tensor[DType.int64]:
        var input_string_py = self._list_of_string_to_py_list(input_string)
        var tokenized_py = self._tokenizer_handle(input_string_py)
        var token_ids = AutoTokenizer._numpy_to_tensor[DType.int64](
            self._numpy_module.array(tokenized_py["input_ids"])
        )
        return token_ids^

    fn decode(self, output_tokens: Tensor[DType.int64]) raises -> List[String]:
        var input_np = self._tensor_to_numpy(output_tokens)
        var result_py = self._tokenizer_handle.batch_decode(input_np)
        var str_list = List[String]()
        for i in range(len(result_py)):
            str_list.append(result_py[i])
        return str_list
