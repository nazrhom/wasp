module ExternalCode
  ( File,
    filePathInExtCodeDir,
    fileAbsPath,
    fileText,
    readFiles,
    SourceExternalCodeDir,
  )
where

import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text.Lazy as TextL
import qualified Data.Text.Lazy.IO as TextL.IO
import StrongPath (Abs, Dir, File', Path', Rel, relfile, (</>))
import qualified StrongPath as SP
import System.IO.Error (isDoesNotExistError)
import UnliftIO.Exception (catch, throwIO)
import qualified Util.IO
import WaspignoreFile (ignores, readWaspignoreFile)

-- | External code directory in Wasp source, from which external code files are read.
data SourceExternalCodeDir

data File = File
  { _pathInExtCodeDir :: !(Path' (Rel SourceExternalCodeDir) File'),
    _extCodeDirPath :: !(Path' Abs (Dir SourceExternalCodeDir)),
    -- | File content. It will throw error when evaluated if file is not textual file.
    _text :: TextL.Text
  }

instance Show File where
  show = show . _pathInExtCodeDir

instance Eq File where
  f1 == f2 = _pathInExtCodeDir f1 == _pathInExtCodeDir f2

-- | Returns path relative to the external code directory.
filePathInExtCodeDir :: File -> Path' (Rel SourceExternalCodeDir) File'
filePathInExtCodeDir = _pathInExtCodeDir

-- | Unsafe method: throws error if text could not be read (if file is not a textual file)!
fileText :: File -> Text
fileText = TextL.toStrict . _text

-- | Returns absolute path of the external code file.
fileAbsPath :: ExternalCode.File -> Path' Abs File'
fileAbsPath file = _extCodeDirPath file </> _pathInExtCodeDir file

waspignorePathInExtCodeDir :: Path' (Rel SourceExternalCodeDir) File'
waspignorePathInExtCodeDir = [relfile|.waspignore|]

-- | Returns all files contained in the specified external code dir, recursively,
--   except files ignores by the specified waspignore file.
readFiles :: Path' Abs (Dir SourceExternalCodeDir) -> IO [File]
readFiles extCodeDirPath = do
  let waspignoreFilePath = extCodeDirPath </> waspignorePathInExtCodeDir
  waspignoreFile <- readWaspignoreFile waspignoreFilePath
  relFilePaths <-
    filter (not . ignores waspignoreFile . SP.toFilePath)
      <$> Util.IO.listDirectoryDeep extCodeDirPath
  let absFilePaths = map (extCodeDirPath </>) relFilePaths
  -- NOTE: We read text from all the files, regardless if they are text files or not, because
  --   we don't know if they are a text file or not.
  --   Since we do lazy reading (Text.Lazy), this is not a problem as long as we don't try to use
  --   text of a file that is actually not a text file -> then we will get an error when Haskell
  --   actually tries to read that file.
  -- TODO: We are doing lazy IO here, and there is an idea of it being a thing to avoid, due to no
  --   control over when resources are released and similar.
  --   If we do figure out that this is causing us problems, we could do the following refactoring:
  --     Don't read files at this point, just list them, and Wasp will contain just list of filepaths.
  --     Modify TextFileDraft so that it also takes text transformation function (Text -> Text),
  --     or create new file draft that will support that.
  --     In generator, when creating TextFileDraft, give it function/logic for text transformation,
  --     and it will be taken care of when draft will be written to the disk.
  fileTexts <- catMaybes <$> mapM (tryReadFile . SP.toFilePath) absFilePaths
  let files = map (\(path, text) -> File path extCodeDirPath text) (zip relFilePaths fileTexts)
  return files
  where
    -- NOTE(matija): we had cases (e.g. tmp Vim files) where a file initially existed
    -- but then got deleted before actual reading was invoked.
    -- That would make this function crash, so we just ignore those errors.
    tryReadFile :: FilePath -> IO (Maybe TextL.Text)
    tryReadFile fp =
      (Just <$> TextL.IO.readFile fp)
        `catch` ( \e ->
                    if isDoesNotExistError e
                      then return Nothing
                      else throwIO e
                )
