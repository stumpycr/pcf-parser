# PCF Parser

A parser for `.pcf` bitmap fonts

## Usage

### Install the `pcf-parser` shard

1. `shards init`
2. Add the dependency to the `shard.yml` file
 ``` yaml
 ...
 dependencies:
   pcf-parser:
     github: l3kn/pcf-parser
 ...
 ```
3. `shards install`

### Read a font file

``` crystal
require "pcf-parser"

font = PCFParser::Font.from_file("./font.pcf")

# look up chars by their "name" (e.g. 'A', 'B') or their "number" (e.g. 65)
#
# font.lookup("test") returns an array of characters

char = font.lookup('A')

height = char.ascent + char.descent
width = char.width

(0...height).each do |y|
  (0...width).each do |x|
    print char.get(x, y) ? "#" : " "
  end
  print "\n"
end
```

__Output:__

```



    ##
   ####
  ##  ##
  ##  ##
 ##    ##
 ##    ##
 ##    ##
 ########
 ##    ##
 ##    ##
 ##    ##
 ##    ##
 ##    ##




```

## TODO

* Implement support for reverse bit order
* Documentation
* Add a collection of `.pcf` fonts
