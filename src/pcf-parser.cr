module PCFParser
  @[Flags]
  enum TableType : Int32
    Properties
    Accelerators
    Metrics
    Bitmaps
    InkMetrics
    BDFEncodings
    SWidths
    GlyphNames
    BDFAccelerators
  end

  class Font
    HEADER = "\1fcp"

    getter encoding : Hash(Int16, Int16)
    getter characters : Array(Character)

    getter max_ascent : Int32
    getter max_descent : Int32

    def self.from_file(filename)
      self.new(File.open(filename))
    end

    def initialize(io)
      raise "Not a PCF file" if io.size < 4
      header = io.read_string(4)
      raise "Not a PCF file" unless header == HEADER

      table_count = io.read_bytes(Int32, IO::ByteFormat::LittleEndian)
      toc_entries = [] of TocEntry

      table_count.times do
        toc_entries << TocEntry.new(io)
      end

      bitmap_table = nil
      metrics_table = nil
      encoding_table = nil

      @encoding = {} of Int16 => Int16

      toc_entries.each do |entry|
        io.seek(entry.offset)

        case entry.type
          # when TableType::Properties
          #   @properties_table = PropertiesTable.new(io)
          when TableType::Bitmaps
            bitmap_table = BitmapTable.new(io)
          when TableType::Metrics
            metrics_table = MetricsTable.new(io)
          when TableType::BDFEncodings
            encoding_table = EncodingTable.new(io)
        end
      end

      raise "Could not find a bitmap table" if bitmap_table.nil?
      raise "Could not find a metrics table" if metrics_table.nil?

      bitmaps = bitmap_table.bitmaps
      metrics = metrics_table.metrics

      if bitmaps.size != metrics.size
        raise "Bitmap and metrics tables are not of the same size"
      end

      unless encoding_table.nil?
        @encoding = encoding_table.encoding
      end

      @characters = [] of Character

      @max_ascent = 0
      @max_descent = 0

      bitmaps.each_with_index do |bitmap, i|
        metric = metrics[i]

        if metric.character_ascent > @max_ascent
          @max_ascent += metric.character_ascent
        end

        if metric.character_descent > @max_descent
          @max_descent += metric.character_descent
        end

        char = Character.new(
          bitmap,
          metric.character_width,
          metric.character_ascent,
          metric.character_descent,
          metric.left_sided_bearing,
          metric.right_sided_bearing,
          bitmap_table.data_bytes,
          bitmap_table.padding_bytes,
        )

        @characters << char
      end
    end

    def lookup(str : String)
      str.chars.map { |c| lookup(c) }
    end

    def lookup(char : Char)
      lookup(char.ord)
    end

    def lookup(char)
      @characters[@encoding[char]]
    end
  end

  class EncodingTable
    getter encoding : Hash(Int16, Int16)

    def initialize(io)
      format = io.read_bytes(Int32, IO::ByteFormat::LittleEndian)

      byte_mask = (format & 4) != 0 # set => most significant byte first
      bit_mask = (format & 8) != 0  # set => most significant bit first

      puts "Unsupported bit_mask: #{bit_mask}" unless bit_mask
      byte_format = byte_mask ? IO::ByteFormat::BigEndian : IO::ByteFormat::BigEndian

      min_char = io.read_bytes(Int16, byte_format)
      max_char = io.read_bytes(Int16, byte_format)
      min_byte = io.read_bytes(Int16, byte_format)
      max_byte = io.read_bytes(Int16, byte_format)

      default_char = io.read_bytes(Int16, byte_format)

      @encoding = Hash(Int16, Int16).new(default_char)

      (min_byte..max_byte).each do |max|
        (min_char..max_char).each do |min|
          full = min | (max << 8)
          value = io.read_bytes(Int16, byte_format)

          if value != 0xffff
            @encoding[full] = value
          else
            @encoding[full] = default_char
          end
        end
      end
    end
  end

  class Character
    getter width : Int16
    getter ascent : Int16
    getter descent : Int16

    getter left_sided_bearing : Int16
    getter right_sided_bearing : Int16

    @padding_bytes : Int32
    @data_bytes : Int32
    @bytes : Bytes

    @bytes_per_row : Int32

    def initialize(@bytes, @width, @ascent, @descent, @left_sided_bearing, @right_sided_bearing, @data_bytes, @padding_bytes)
      @bytes_per_row = [(@width / 8).to_i32, 1].max

      # Pad as needed
      if (@bytes_per_row % @padding_bytes) != 0
        @bytes_per_row += @padding_bytes - (@bytes_per_row % @padding_bytes)
      end

      # TODO: Is this last row relevant?
      @bytes_per_row = [@bytes_per_row, @data_bytes].max

      # needed = @bytes_per_row * (@ascent + @descent)
      # got = @bytes.size
    end

    def get(x, y)
      unless 0 <= x < @width
        raise "Invalid x value: #{x}, must be in range (0..#{@width})"
      end

      unless 0 <= y < (@ascent + @descent)
        raise "Invalid y value: #{y}, must be in range (0..#{@ascent + @descent})"
      end

      index = x / 8 + @bytes_per_row * y
      shift = 7 - (x % 8)

      if index < @bytes.size
        @bytes[index] & (1 << (7 - (x % 8))) != 0
      else
        true
      end
    end
  end

  class TocEntry
    getter type : TableType
    getter format : Int32
    getter size : Int32
    getter offset : Int32

    def initialize(io)
      @type = TableType.new(io.read_bytes(Int32, IO::ByteFormat::LittleEndian))
      @format = io.read_bytes(Int32, IO::ByteFormat::LittleEndian)
      @size   = io.read_bytes(Int32, IO::ByteFormat::LittleEndian)
      @offset = io.read_bytes(Int32, IO::ByteFormat::LittleEndian)
    end
  end

  class Prop
    getter name_offset : Int32
    getter is_string_prop : Bool
    getter value : Int32

    def initialize(io, byte_format)
      @name_offset = io.read_bytes(Int32, byte_format)
      @is_string_prop = io.read_bytes(Int8, byte_format) == 1
      @value = io.read_bytes(Int32, byte_format)
    end
  end

  class Metric
    getter left_sided_bearing : Int16
    getter right_sided_bearing : Int16
    getter character_width : Int16
    getter character_ascent : Int16
    getter character_descent : Int16
    getter character_attributes : UInt16

    def initialize(io, compressed, byte_format)
      if compressed
        @left_sided_bearing   = io.read_bytes(UInt8, byte_format).to_i16 - 0x80
        @right_sided_bearing  = io.read_bytes(UInt8, byte_format).to_i16 - 0x80
        @character_width      = io.read_bytes(UInt8, byte_format).to_i16 - 0x80
        @character_ascent     = io.read_bytes(UInt8, byte_format).to_i16 - 0x80
        @character_descent    = io.read_bytes(UInt8, byte_format).to_i16 - 0x80
        @character_attributes = 0_u16
      else
        @left_sided_bearing   = io.read_bytes(Int16, byte_format)
        @right_sided_bearing  = io.read_bytes(Int16, byte_format)
        @character_width      = io.read_bytes(Int16, byte_format)
        @character_ascent     = io.read_bytes(Int16, byte_format)
        @character_descent    = io.read_bytes(Int16, byte_format)
        @character_attributes = io.read_bytes(UInt16, byte_format)
      end
    end
  end

  class MetricsTable
    getter metrics : Array(Metric)

    def initialize(io)
      format = io.read_bytes(Int32, IO::ByteFormat::LittleEndian)

      byte_mask = (format & 4) != 0 # set => most significant byte first
      bit_mask = (format & 8) != 0  # set => most significant bit first

      puts "Unsupported bit_mask: #{bit_mask}" unless bit_mask
      byte_format = byte_mask ? IO::ByteFormat::BigEndian : IO::ByteFormat::BigEndian

      # :compressed_metrics is equiv. to :accel_w_inkbounds
      main_format = [:default, :compressed_metrics, :inkbounds][format >> 8]

      @metrics = [] of Metric
      if main_format == :compressed_metrics
        metrics_count = io.read_bytes(Int16, byte_format)
        metrics_count.times do
          @metrics << Metric.new(io, true, byte_format)
        end
      else
        metrics_count = io.read_bytes(Int32, byte_format)
        metrics_count.times do
          @metrics << Metric.new(io, false, byte_format)
        end
      end
    end
  end

  class BitmapTable
    getter bitmaps : Array(Bytes)
    getter padding_bytes : Int32
    getter data_bytes : Int32

    # TODO: Raise if format != PCF_DEFAULT
    def initialize(io)
      format = io.read_bytes(Int32, IO::ByteFormat::LittleEndian)

      # 0 => byte (8bit), 1 => short (16bit), 2 => int (32bit)
      # TODO: What is this needed for?
      glyph_pad = format & 3
      @padding_bytes = glyph_pad == 0 ? 1 : glyph_pad * 2

      byte_mask = (format & 4) != 0 # set => most significant byte first
      bit_mask = (format & 8) != 0  # set => most significant bit first

      # 0 => byte (8bit), 1 => short (16bit), 2 => int (32bit)
      scan_unit = (format >> 4) & 3
      @data_bytes = scan_unit == 0 ? 1 : scan_unit * 2

      puts "Unsupported bit_mask: #{bit_mask}" unless bit_mask
      byte_format = byte_mask ? IO::ByteFormat::BigEndian : IO::ByteFormat::BigEndian

      # :compressed_metrics is equiv. to :accel_w_inkbounds
      main_format = [:default, :inkbounds, :compressed_metrics][format >> 8]

      glyph_count = io.read_bytes(Int32, byte_format)
      offsets = [] of Int32

      glyph_count.times do
        offsets << io.read_bytes(Int32, byte_format)
      end

      bitmap_sizes = [] of Int32
      4.times do
        bitmap_sizes << io.read_bytes(Int32, byte_format)
      end

      @bitmaps = [] of Bytes

      slice = Bytes.new(bitmap_sizes[glyph_pad])
      read = io.read_fully(slice)

      raise "Failed to read bitmap data" if bitmap_sizes[glyph_pad] != read

      offsets.each do |off|
        @bitmaps << (slice + off)
      end

      # bitmap_data = io.pos
      # offsets.each do |off|
      #   size = bitmap_sizes[glyph_pad] / glyph_count
      #   slice = Bytes.new(size)

      #   io.seek(bitmap_data + off) do
      #     n_read = io.read(slice)
      #     raise "Failed to read bitmap data" if n_read != size
      #     @bitmaps << slice
      #   end
      # end
    end
  end

  class PropertiesTable
    getter properties : Hash(String, (String | Int32))

    def initialize(io)
      @properties = {} of String => (String | Int32)

      format = io.read_bytes(Int32, IO::ByteFormat::LittleEndian)
      byte_mask = (format & 4) != 0 # set => most significant byte first
      bit_mask = (format & 8) != 0  # set => most significant bit first

      unless bit_mask
        puts "Unsupported bit_mask: #{bit_mask}"
      end

      byte_format = byte_mask ? IO::ByteFormat::BigEndian : IO::ByteFormat::BigEndian

      # :compressed_metrics is equiv. to :accel_w_inkbounds
      main_format = [:default, :inkbounds, :compressed_metrics][format >> 8]

      size = io.read_bytes(Int32, byte_format)
      props = [] of Prop
      size.times do
        props << Prop.new(io, byte_format)
      end

      padding = (size & 3) == 0 ? 0 : 4 - (size & 3)
      io.skip(padding)

      string_size = io.read_bytes(Int32, byte_format)

      # Start of the strings array
      strings = io.pos
      props.each do |prop|
        name = nil
        io.seek(strings + prop.name_offset) do
          name = io.gets('\0', true)
        end

        raise "Could not read property name" if name.nil?

        offset = prop.value
        if prop.is_string_prop
          io.seek(strings + offset) do
            value = io.gets('\0', true)
            raise "Could not read property value" if value.nil?
            @properties[name] = value
          end
        else
          @properties[name] = offset
        end
      end
    end
  end
end
