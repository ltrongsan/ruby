# frozen_string_literal: true

require "parser"

module Prism
  module Translation
    # This class is the entry-point for converting a prism syntax tree into the
    # whitequark/parser gem's syntax tree. It inherits from the base parser for
    # the parser gem, and overrides the parse* methods to parse with prism and
    # then translate.
    class Parser < ::Parser::Base
      # The parser gem has a list of diagnostics with a hard-coded set of error
      # messages. We create our own diagnostic class in order to set our own
      # error messages.
      class Diagnostic < ::Parser::Diagnostic
        # The message generated by prism.
        attr_reader :message

        # Initialize a new diagnostic with the given message and location.
        def initialize(message, level, reason, location)
          @message = message
          super(level, reason, {}, location, [])
        end
      end

      Racc_debug_parser = false # :nodoc:

      def version # :nodoc:
        34
      end

      # The default encoding for Ruby files is UTF-8.
      def default_encoding
        Encoding::UTF_8
      end

      def yyerror # :nodoc:
      end

      # Parses a source buffer and returns the AST.
      def parse(source_buffer)
        @source_buffer = source_buffer
        source = source_buffer.source

        offset_cache = build_offset_cache(source)
        result = unwrap(Prism.parse(source, filepath: source_buffer.name, version: convert_for_prism(version)), offset_cache)

        build_ast(result.value, offset_cache)
      ensure
        @source_buffer = nil
      end

      # Parses a source buffer and returns the AST and the source code comments.
      def parse_with_comments(source_buffer)
        @source_buffer = source_buffer
        source = source_buffer.source

        offset_cache = build_offset_cache(source)
        result = unwrap(Prism.parse(source, filepath: source_buffer.name, version: convert_for_prism(version)), offset_cache)

        [
          build_ast(result.value, offset_cache),
          build_comments(result.comments, offset_cache)
        ]
      ensure
        @source_buffer = nil
      end

      # Parses a source buffer and returns the AST, the source code comments,
      # and the tokens emitted by the lexer.
      def tokenize(source_buffer, recover = false)
        @source_buffer = source_buffer
        source = source_buffer.source

        offset_cache = build_offset_cache(source)
        result =
          begin
            unwrap(Prism.parse_lex(source, filepath: source_buffer.name, version: convert_for_prism(version)), offset_cache)
          rescue ::Parser::SyntaxError
            raise if !recover
          end

        program, tokens = result.value
        ast = build_ast(program, offset_cache) if result.success?

        [
          ast,
          build_comments(result.comments, offset_cache),
          build_tokens(tokens, offset_cache)
        ]
      ensure
        @source_buffer = nil
      end

      # Since prism resolves num params for us, we don't need to support this
      # kind of logic here.
      def try_declare_numparam(node)
        node.children[0].match?(/\A_[1-9]\z/)
      end

      private

      # This is a hook to allow consumers to disable some errors if they don't
      # want them to block creating the syntax tree.
      def valid_error?(error)
        true
      end

      # This is a hook to allow consumers to disable some warnings if they don't
      # want them to block creating the syntax tree.
      def valid_warning?(warning)
        true
      end

      # If there was a error generated during the parse, then raise an
      # appropriate syntax error. Otherwise return the result.
      def unwrap(result, offset_cache)
        result.errors.each do |error|
          next unless valid_error?(error)

          location = build_range(error.location, offset_cache)
          diagnostics.process(Diagnostic.new(error.message, :error, :prism_error, location))
        end
        result.warnings.each do |warning|
          next unless valid_warning?(warning)

          location = build_range(warning.location, offset_cache)
          diagnostics.process(Diagnostic.new(warning.message, :warning, :prism_warning, location))
        end

        result
      end

      # Prism deals with offsets in bytes, while the parser gem deals with
      # offsets in characters. We need to handle this conversion in order to
      # build the parser gem AST.
      #
      # If the bytesize of the source is the same as the length, then we can
      # just use the offset directly. Otherwise, we build an array where the
      # index is the byte offset and the value is the character offset.
      def build_offset_cache(source)
        if source.bytesize == source.length
          -> (offset) { offset }
        else
          offset_cache = []
          offset = 0

          source.each_char do |char|
            char.bytesize.times { offset_cache << offset }
            offset += 1
          end

          offset_cache << offset
        end
      end

      # Build the parser gem AST from the prism AST.
      def build_ast(program, offset_cache)
        program.accept(Compiler.new(self, offset_cache))
      end

      # Build the parser gem comments from the prism comments.
      def build_comments(comments, offset_cache)
        comments.map do |comment|
          ::Parser::Source::Comment.new(build_range(comment.location, offset_cache))
        end
      end

      # Build the parser gem tokens from the prism tokens.
      def build_tokens(tokens, offset_cache)
        Lexer.new(source_buffer, tokens.map(&:first), offset_cache).to_a
      end

      # Build a range from a prism location.
      def build_range(location, offset_cache)
        ::Parser::Source::Range.new(
          source_buffer,
          offset_cache[location.start_offset],
          offset_cache[location.end_offset]
        )
      end

      # Converts the version format handled by Parser to the format handled by Prism.
      def convert_for_prism(version)
        case version
        when 33
          "3.3.0"
        when 34
          "3.4.0"
        else
          "latest"
        end
      end

      require_relative "parser/compiler"
      require_relative "parser/lexer"

      private_constant :Compiler
      private_constant :Lexer
    end
  end
end
