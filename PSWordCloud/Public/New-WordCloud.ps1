﻿class SizeTransformAttribute : ArgumentTransformationAttribute {
    static [hashtable] $StandardSizes = @{
        '720p'  = [Size]::new(1280, 720)
        '1080p' = [Size]::new(1920, 1080)
        '4K'    = [Size]::new(4096, 2160)
    }

    [object] Transform([EngineIntrinsics]$engineIntrinsics, [object] $inputData) {
        $Size = switch ($inputData) {
            { $_ -is [Size] } {
                $_
                break
            }
            { $_ -is [SizeF] } {
                $_.ToSize()
                break
            }
            { $_ -is [int] -or $_ -is [double] } {
                [Size]::new($_, $_)
                break
            }
            { $_ -in [SizeTransformAttribute]::StandardSizes.Keys } {
                [SizeTransformAttribute]::StandardSizes[$_]
                break
            }
            { $_ -is [string] } {
                if ($_ -match '^(?<Width>[\d\.,]+)x(?<Height>[\d\.,]+)(px)?$') {
                    [Size]::new($Matches['Width'], $Matches['Height'])
                    break
                }

                if ($_ -match '^(?<Size>[\d\.,]+)(px)?$') {
                    [Size]::new($Matches['Size'], $Matches['Size'])
                    break
                }
            }
            default {
                throw [ArgumentTransformationMetadataException]::new("Unable to convert entered value $inputData to a valid [System.Drawing.Size].")
            }
        }

        $Area = $Size.Height * $Size.Width
        if ($Area -ge 100 * 100 -and $Area -le 20000 * 20000) {
            return $Size
        }
        else {
            throw [ArgumentTransformationMetadataException]::new(
                "Specified size $inputData is either too small to use for an image size, or would exceed GDI+ limitations."
            )
        }
    }
}

class ColorTransformAttribute : ArgumentTransformationAttribute {
    static [string[]] $ColorNames = @(
        [KnownColor].GetEnumNames()
        "Transparent"
    )

    [object] Transform([EngineIntrinsics]$engineIntrinsics, [object] $inputData) {
        $Items = switch ($inputData) {
            { $_ -eq $null -or $_ -eq 'Transparent' } {
                [Color]::Transparent
                continue
            }
            { $_ -as [KnownColor] } {
                [Color]::FromKnownColor($_ -as [KnownColor])
                continue
            }
            { $_ -is [Color] } {
                $_
                continue
            }
            { $_ -is [string] } {
                if ($_ -match 'R(?<Red>[0-9]{1,3})G(?<Green>[0-9]{1,3})B(?<Blue>[0-9]{1,3})') {
                    [Color]::FromArgb($Matches['Red'], $Matches['Green'], $Matches['Blue'])
                    continue
                }

                if ($_ -match 'R(?<Red>[0-9]{1,3})G(?<Green>[0-9]{1,3})B(?<Blue>[0-9]{1,3})A(?<Alpha>[0-9]{1,3})') {
                    [Color]::FromArgb($Matches['Alpha'], $Matches['Red'], $Matches['Green'], $Matches['Blue'])
                    continue
                }
            }
            { $- -is [int] } {
                [Color]::FromArgb($_)
                continue
            }
            default {
                throw [ArgumentTransformationMetadataException]::new("Could not convert value '$_' to a valid [System.Drawing.Color] or [System.Drawing.KnownColor].")
            }
        }

        return $Items
    }
}

class FileTransformAttribute : ArgumentTransformationAttribute {
    [object] Transform([EngineIntrinsics]$engineIntrinsics, [object] $inputData) {
        $Items = switch ($inputData) {
            { $_ -as [FileInfo] } {
                $_
                break
            }
            { $_ -is [string] } {
                $Path = Resolve-Path -Path $_
                if (@($Path).Count -gt 1) {
                    throw [ArgumentTransformationMetadataException]::new("Multiple files found, please enter only one: $($Path -join ', ')")
                }

                if (Test-Path -Path $Path -PathType Leaf) {
                    [FileInfo]::new($Path)
                }

                break
            }
            default {
                throw [ArgumentTransformationMetadataException]::new("Could not convert value '$_' to a valid [System.IO.FileInfo] object.")
            }
        }

        return $Items
    }
}

function New-WordCloud {
    <#
    .SYNOPSIS
    Creates a word cloud from the input text.

    .DESCRIPTION
    Measures the frequency of use of each word, taking into account plural and similar forms, and creates an image
    with each word's visual size corresponding to the frequency of occurrence in the input text.

    .PARAMETER InputObject
    The string data to examine and create the word cloud image from. Any non-string data piped in will be passed through
    Out-String first to obtain a proper string representation of the object, which will then be broken down into its
    constituent words.

    .PARAMETER Path
    The output path of the word cloud.

    .PARAMETER ColorSet
    Define a set of colors to use when rendering the word cloud. Any array of values in any mix of the following formats
    is acceptable:

    - Valid [System.Drawing.Color] objects
    - Valid [System.Drawing.KnownColor] values in enum or string format
    - Strings of the format r255g255b255 or r255g255b255a255 where the integers are the R, G, B, and optionally Alpha
      values of the desired color.
    - Any valid integer value; these are passed directly to [System.Drawing.Color]::FromArgb($Integer) to be converted
      into valid colors.

    .PARAMETER MaxColors
    Limit the maximum number of colors from either the standard or custom set that will be used. A random selection of
    this many colors will be used to render the word cloud.

    .PARAMETER FontFamily
    Specify the font family as a string or [FontFamily] value. System.Drawing supports primarily TrueType fonts.

    .PARAMETER FontStyle
    Specify the font style to use for the word cloud.

    .PARAMETER ImageSize
    Specify the image size to use in pixels. The image dimensions can be any value between 500 and 20,000px. Any of the
    following size specifier formats are permitted:

    - Any valid [System.Drawing.Size] object
    - Any valid [System.Drawing.SizeF] object
    - 1000x1000
    - 1000x1000px
    - 1000
    - 1000px
    - 720p	        (Creates an image of size 1280x720px)
    - 1080p         (Creates an image of size 1920x1080px)
    - 4K	        (Creates an image of size 4096x2160px)

    4096x2160 will be used by default. Note that the minimum image resolution is 10,000 pixels (100 x 100px), and the
    maximum resolution is 400,000,000 pixels (20,000 x 20,000px, 400MP).

    .PARAMETER DistanceStep
    The number of pixels to increment per radial sweep. Higher values will make the operation quicker, but may reduce
    the effectiveness of the packing algorithm. Lower values will take longer, but will generally ensure a more
    tightly-packed word cloud.

    .PARAMETER RadialGranularity
    The number of radial points at each distance step to check during a single sweep. This value is scaled as the radius
    expands to retain some consistency in the overall step distance as the distance from the center increases.

    .PARAMETER BackgroundColor
    Set the background color of the image. Colors with similar names to the background color are automatically excluded
    from being selected for use in word coloring. Any value in of the following formats is acceptable:

    - Valid [System.Drawing.Color] objects
    - Valid [System.Drawing.KnownColor] values in enum or string format
    - Strings of the format r255g255b255 or r255g255b255a255 where the integers are the R, G, B, and optionally Alpha
      values of the desired color.
    - Any valid integer value; these are passed directly to [System.Drawing.Color]::FromArgb($Integer) to be converted
      into valid colors.

    Specify $null or Transparent as the background color value to render the word cloud on a transparent background.

    .PARAMETER Monochrome
    Use only shades of grey to create the word cloud.

    .PARAMETER OutputFormat
    Specify the output image file format to use.

    .PARAMETER MaxWords
    Specify the maximum number of words to include in the word cloud. 100 is default. If there are fewer unique words
    than the maximum amount, all unique words will be rendered.

    .PARAMETER BackgroundImage
    Specify the background image to be used as a base for the word cloud image. The original image size will be retained.

    .PARAMETER DisableWordRotation
    Disables rotated words in the final image.

    .EXAMPLE
    Get-Content .\Words.txt | New-WordCloud -Path .\WordCloud.png

    Generates a word cloud from the words in the specified file, and saves it to the specified image file.

    .NOTES
    Only the top 100 most frequent words will be included in the word cloud by default; typically, words that fall under
    this ranking end up being impossible to render cleanly except on very high resolutions.

    The word cloud will be rendered according to the image size; landscape or portrait configurations will result in
    ovoid clouds, whereas square images will result mainly in circular clouds.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ColorBackground')]
    [Alias('wordcloud', 'wcloud')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'ColorBackground')]
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'ColorBackground-Mono')]
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'FileBackground')]
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'FileBackground-Mono')]
        [Alias('InputString', 'Text', 'String', 'Words', 'Document', 'Page')]
        [AllowEmptyString()]
        [object[]]
        $InputObject,

        [Parameter(Mandatory, Position = 1, ParameterSetName = 'ColorBackground')]
        [Parameter(Mandatory, Position = 1, ParameterSetName = 'ColorBackground-Mono')]
        [Parameter(Mandatory, Position = 1, ParameterSetName = 'FileBackground')]
        [Parameter(Mandatory, Position = 1, ParameterSetName = 'FileBackground-Mono')]
        [Alias('OutFile', 'ExportPath', 'ImagePath')]
        [ValidateScript(
            { Test-Path -IsValid $_ -PathType Leaf }
        )]
        [string[]]
        $Path,

        [Parameter(ParameterSetName = 'ColorBackground')]
        [Parameter(ParameterSetName = 'ColorBackground-Mono')]
        [Parameter(ParameterSetName = 'FileBackground')]
        [Parameter(ParameterSetName = 'FileBackground-Mono')]
        [Alias('ColourSet')]
        [ArgumentCompleter(
            {
                param($Command, $Parameter, $WordToComplete, $CommandAst, $FakeBoundParams)
                if (!$WordToComplete) {
                    return [ColorTransformAttribute]::ColorNames
                }
                else {
                    return [ColorTransformAttribute]::ColorNames.Where{ $_.StartsWith($WordToComplete) }
                }
            }
        )]
        [ColorTransformAttribute()]
        [Color[]]
        $ColorSet = [ColorTransformAttribute]::ColorNames,

        [Parameter()]
        [Alias('MaxColours')]
        [int]
        $MaxColors = [int]::MaxValue,

        [Parameter()]
        [Alias('FontFace')]
        [ArgumentCompleter(
            {
                param($Command, $Parameter, $WordToComplete, $CommandAst, $FakeBoundParams)
                $FontLibrary = [FontFamily]::Families.Name.Where{-not [string]::IsNullOrWhiteSpace($_)}

                if (!$WordToComplete) {
                    return $FontLibrary -replace '(?="|`|\$)', '`' -replace '^|$', '"'
                }
                else {
                    return $FontLibrary.Where{$_ -match "^('|`")?$([regex]::Escape($WordToComplete))"} -replace '(?="|`|\$)', '`' -replace '^|$', '"'
                }
            }
        )]
        [FontFamily]
        $FontFamily = [FontFamily]::new('Consolas'),

        [Parameter()]
        [FontStyle]
        $FontStyle = [FontStyle]::Regular,

        [Parameter(ParameterSetName = 'ColorBackground')]
        [Parameter(ParameterSetName = 'ColorBackground-Mono')]
        [Alias('ImagePixelSize')]
        [ArgumentCompleter(
            {
                param($Command, $Parameter, $WordToComplete, $CommandAst, $FakeBoundParams)

                $Values = @('720p', '1080p', '4K', '640x1146', '480x800')

                if ($WordToComplete) {
                    return $Values.Where{$_ -match "^$WordToComplete"}
                }
                else {
                    return $Values
                }
            }
        )]
        [SizeTransformAttribute()]
        [Size]
        $ImageSize = [Size]::new(4096, 2160),

        [Parameter()]
        [ValidateRange(1, 500)]
        $DistanceStep = 5,

        [Parameter()]
        [ValidateRange(1, 50)]
        $RadialGranularity = 15,

        [Parameter(ParameterSetName = 'ColorBackground')]
        [Parameter(ParameterSetName = 'ColorBackground-Mono')]
        [Alias('BackgroundColour')]
        [ArgumentCompleter(
            {
                param($Command, $Parameter, $WordToComplete, $CommandAst, $FakeBoundParams)
                if (!$WordToComplete) {
                    return [ColorTransformAttribute]::ColorNames
                }
                else {
                    return [ColorTransformAttribute]::ColorNames.Where{ $_.StartsWith($WordToComplete) }
                }
            }
        )]
        [ColorTransformAttribute()]
        [Color]
        $BackgroundColor = [Color]::Black,

        [Parameter(Mandatory, ParameterSetName = 'ColorBackground-Mono')]
        [Parameter(Mandatory, ParameterSetName = 'FileBackground-Mono')]
        [Alias('Greyscale', 'Grayscale')]
        [switch]
        $Monochrome,

        [Parameter()]
        [Alias('ImageFormat', 'Format')]
        [ValidateSet("Bmp", "Emf", "Exif", "Gif", "Jpeg", "Png", "Tiff", "Wmf")]
        [string]
        $OutputFormat = "Png",

        [Parameter()]
        [Alias('MaxWords')]
        [ValidateRange(10, 500)]
        [int]
        $MaxUniqueWords = 100,

        [Parameter()]
        [Alias('DisableRotation', 'NoRotation')]
        [switch]
        $DisableWordRotation,

        [Parameter(Mandatory, ParameterSetName = 'FileBackground')]
        [Parameter(Mandatory, ParameterSetName = 'FileBackground-Mono')]
        [Alias('BaseImage')]
        [FileTransformAttribute()]
        [FileInfo]
        $BackgroundImage
    )
    begin {
        Write-Debug "Color set: $($ColorSet -join ', ')"
        Write-Debug "Background color: $BackgroundColor"

        $ExcludedWords = (Get-Content "$script:ModuleRoot/Data/StopWords.txt") -join '|'
        $SplitChars = " `n.,`"?!{}[]:()`“`”™*#%^&+=" -as [char[]]
        $ColorIndex = 0
        $RadialDistance = 0

        $WordList = [List[string]]::new()
        $WordHeightTable = @{}
        $WordSizeTable = @{}

        $ExportFormat = $OutputFormat | Get-ImageFormat

        if ($PSCmdlet.ParameterSetName -eq 'Monochrome') {
            $MinSaturation = 0
        }
        else {
            $MinSaturation = 0.5
        }

        $PathList = foreach ($FilePath in $Path) {
            if ($FilePath -notmatch "\.$OutputFormat$") {
                $FilePath += $OutputFormat
            }
            if (-not (Test-Path -Path $FilePath)) {
                (New-Item -ItemType File -Path $FilePath).FullName
            }
            else {
                (Get-Item -Path $FilePath).FullName
            }
        }

        $ColorList = $ColorSet |
            Sort-Object {Get-Random} |
            Select-Object -First $MaxColors |
            ForEach-Object {
            if (-not $Monochrome) {
                $_
            }
            else {
                [int]$Brightness = $_.GetBrightness() * 255
                [Color]::FromArgb($Brightness, $Brightness, $Brightness)
            }
        } | Where-Object {
            if ($BackgroundColor) {
                $_.Name -notmatch $BackgroundColor -and
                $_.GetSaturation() -ge $MinSaturation
            }
            else {
                $_.GetSaturation() -ge $MinSaturation
            }
        } | Sort-Object -Descending {
            $Value = $_.GetBrightness()
            $Random = (-$Value..$Value | Get-Random) / (1 - $_.GetSaturation())
            $Value + $Random
        }
    }
    process {
        $Lines = ($InputObject | Out-String) -split '\r?\n'
        $WordList.AddRange(
            $Lines.Split($SplitChars, [StringSplitOptions]::RemoveEmptyEntries).Where{
                $_ -notmatch "^($ExcludedWords)s?$|^[^a-z]+$|[^a-z0-9'_-]" -and $_.Length -gt 1
            } -replace "^('|_)|('|_)$" -as [string[]]
        )
    }
    end {
        # Count occurrence of each word
        switch ($WordList) {
            { $WordHeightTable[($_ -replace 's$')] } {
                $WordHeightTable[($_ -replace 's$')] ++
                continue
            }
            { $WordHeightTable["${_}s"] } {
                $WordHeightTable[$_] = $WordHeightTable["${_}s"] + 1
                $WordHeightTable.Remove("${_}s")
                continue
            }
            default {
                $WordHeightTable[$_] ++
                continue
            }
        }

        $WordHeightTable | Out-String | Write-Debug

        $SortedWordList = $WordHeightTable.GetEnumerator().Name |
            Sort-Object -Descending { $WordHeightTable[$_] } |
            Select-Object -First $MaxUniqueWords

        $HighestFrequency, $AverageFrequency = $SortedWordList |
            ForEach-Object { $WordHeightTable[$_] } |
            Measure-Object -Average -Maximum |
            ForEach-Object {$_.Maximum, $_.Average}

        try {
            if ($BackgroundImage.FullName) {
                $WordCloudImage = [Bitmap]::new($BackgroundImage.FullName)
                $DrawingSurface = [Graphics]::FromImage($WordCloudImage)
            }
            else {
                $WordCloudImage = [Bitmap]::new($ImageSize.Width, $ImageSize.Height)
                $DrawingSurface = [Graphics]::FromImage($WordCloudImage)

                $DrawingSurface.Clear($BackgroundColor)
            }

            $FontScale = ($WordCloudImage.Height + $WordCloudImage.Width) / ($AverageFrequency * $SortedWordList.Count)
            $DrawingSurface.SmoothingMode = [Drawing2D.SmoothingMode]::AntiAlias
            $DrawingSurface.TextRenderingHint = [Text.TextRenderingHint]::AntiAlias

            foreach ($Word in $SortedWordList) {
                $WordHeightTable[$Word] = [Math]::Round($WordHeightTable[$Word] * $FontScale)
                if ($WordHeightTable[$Word] -lt 8) { continue }

                $Font = [Font]::new(
                    $FontFamily,
                    $WordHeightTable[$Word],
                    $FontStyle,
                    [GraphicsUnit]::Pixel
                )

                $WordSizeTable[$Word] = $DrawingSurface.MeasureString($Word, $Font)
            }
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
            if ($DrawingSurface) {
                $DrawingSurface.Dispose()
            }
            if ($DummyImage) {
                $WordCloudImage.Dispose()
            }
        }

        $MaxSideLength = [Math]::Max($WordCloudImage.Width, $WordCloudImage.Height)
        $GCD = Get-GreatestCommonDivisor -Numerator $MaxSideLength -Denominator ([Math]::Min($WordCloudImage.Width, $WordCloudImage.Height))
        $AspectRatio = $WordCloudImage.Width / $WordCloudImage.Height
        $CentrePoint = [PointF]::new($WordCloudImage.Width / 2, $WordCloudImage.Height / 2)

        [PSCustomObject]@{
            ExportFormat     = $ExportFormat
            UniqueWords      = $WordHeightTable.GetEnumerator().Name.Count
            HighestFrequency = $HighestFrequency
            AverageFrequency = $AverageFrequency
            MaxFontSize      = $HighestFrequency * $FontScale
            ImageSize        = $WordCloudImage.Size
            ImageCentre      = $CentrePoint
            AspectRatio      = "$($WordCloudImage.Width / $GCD) : $($WordCloudImage.Height / $GCD)"
            FontFamily       = $FontFamily.Name
        } | Format-List | Out-String | Write-Verbose

        try {
            $RectangleList = [List[RectangleF]]::new()
            $RadialScanCount = 0
            $RNG = [Random]::new()

            '{0,-20} | {1,23} | {2,10} | {3,26} | {4,-10}' -f 'Word', 'Color', 'FontSize', 'Location', 'Direction' |
                Write-Verbose
            Write-Verbose "$("-" * 21)+$("-" * 25)+$("-" * 12)+$("-" * 28)+$("-" * 11)"
            :words foreach ($Word in $SortedWordList) {
                if (-not $WordSizeTable[$Word]) { continue }
                $RadialDistance = 0
                $Rotate = !$DisableWordRotation -and $RNG.NextDouble() -gt 0.65

                $Font = [Font]::new(
                    $FontFamily,
                    $WordHeightTable[$Word],
                    $FontStyle,
                    [GraphicsUnit]::Pixel
                )

                $RadialScanCount /= 3
                $WordRectangle = $null
                do {
                    if ( $RadialDistance -gt ($MaxSideLength / 2) ) {
                        $RadialDistance = $MaxSideLength / $DistanceStep / 25
                        continue words
                    }

                    $AngleIncrement = 360 / ( ($RadialDistance + 1) * $RadialGranularity / 10 )
                    switch ([int]$RadialScanCount -band 7) {
                        0 { $Start = 0; $End = 360 }
                        1 { $Start = -90; $End = 270 }
                        2 { $Start = -180; $End = 180 }
                        3 { $Start = -270; $End = 90  }
                        4 { $Start = 360; $End = 0; $AngleIncrement *= -1 }
                        5 { $Start = 270; $End = -90; $AngleIncrement *= -1 }
                        6 { $Start = 180; $End = -180; $AngleIncrement *= -1 }
                        7 { $Start = 90; $End = -270; $AngleIncrement *= -1 }
                    }

                    for (
                        $Angle = $Start;
                        $( if ($Start -lt $End) {$Angle -le $End} else {$End -le $Angle} );
                        $Angle += $AngleIncrement
                    ) {
                        $IsColliding = $false
                        $Radians = Convert-ToRadians -Degrees $Angle
                        $Complex = [Complex]::FromPolarCoordinates($RadialDistance, $Radians)

                        $OffsetX = $WordSizeTable[$Word].Width * 0.5
                        $OffsetY = $WordSizeTable[$Word].Height * 0.5
                        if ($WordHeightTable[$Word] -ne $HighestFrequency * $FontScale -and $AspectRatio -gt 1) {
                            $OffsetX = $OffsetX * $RNG.NextDouble() + 0.25
                            $OffsetY = $OffsetY * $RNG.NextDouble() + 0.25
                        }
                        $DrawLocation = [PointF]::new(
                            $Complex.Real * $AspectRatio + $CentrePoint.X - $OffsetX,
                            $Complex.Imaginary + $CentrePoint.Y - $OffsetY
                        )

                        $WordRectangle = if ($Rotate) {
                            [RectangleF]::new(
                                [PointF]$DrawLocation,
                                [SizeF]::new($WordSizeTable[$Word].Height, $WordSizeTable[$Word].Width)
                            )
                        }
                        else {
                            [RectangleF]::new([PointF]$DrawLocation, [SizeF]$WordSizeTable[$Word])
                        }

                        $OutsideImage = (
                            $WordRectangle.Top -lt 0 -or
                            $WordRectangle.Left -lt 0 -or
                            $WordRectangle.Bottom -gt $WordCloudImage.Height -or
                            $WordRectangle.Right -gt $WordCloudImage.Width
                        )
                        if ($OutsideImage) {
                            continue
                        }

                        foreach ($Rectangle in $RectangleList) {
                            if ($WordRectangle.IntersectsWith($Rectangle)) {
                                $IsColliding = $true
                                break
                            }
                        }

                        if (!$IsColliding) {
                            break
                        }
                    }

                    if ($IsColliding) {
                        $RadialDistance += if ($Rotate) {
                            $WordRectangle.Width * $DistanceStep / 10
                        }
                        else {
                            $WordRectangle.Height * $DistanceStep / 10
                        }
                        $RadialScanCount++
                    }
                } while ($IsColliding)

                $RectangleList.Add($WordRectangle)
                $Color = $ColorList[$ColorIndex]

                $ColorIndex++
                if ($ColorIndex -ge $ColorList.Count) {
                    $ColorIndex = 0
                }

                $FormatString = '{0,-20} | R:{1,3} G:{2,3} B:{3,3} A:{4,3} | {5,10} | {6,26} | {7,-10}'
                if ($Rotate) {
                    $FormatString -f @(
                        "'$Word'"
                        $Color.R
                        $Color.G
                        $Color.B
                        $Color.A
                        "$($Font.SizeInPoints) pt"
                        $DrawLocation.ToString()
                        'Vertical'
                    ) | Write-Verbose
                    $RotateFormat = [StringFormat]::new([StringFormatFlags]::DirectionVertical)
                    $DrawingSurface.DrawString($Word, $Font, [SolidBrush]::new($Color), $DrawLocation, $RotateFormat)
                }
                else {
                    $FormatString -f @(
                        "'$Word'"
                        $Color.R
                        $Color.G
                        $Color.B
                        $Color.A
                        "$($Font.SizeInPoints) pt"
                        $DrawLocation.ToString()
                        'Horizontal'
                    ) | Write-Verbose
                    $DrawingSurface.DrawString($Word, $Font, [SolidBrush]::new($Color), $DrawLocation)
                }
            }

            $DrawingSurface.Flush()
            foreach ($FilePath in $PathList) {
                $WordCloudImage.Save($FilePath, $ExportFormat)
            }
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }
        finally {
            $DrawingSurface.Dispose()
            $WordCloudImage.Dispose()
        }
    }
}