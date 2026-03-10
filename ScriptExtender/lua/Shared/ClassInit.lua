-- File: Mods/BG3Access/ScriptExtender/Lua/Shared/ClassInit.lua

_MetaClass = {
    _ClassName = "BG3AccessMetaClass",
}
_MetaClass.__index = _MetaClass

local _Index = {} 
local _DebugMetaTable = {
    __index = function(proxyTable, key)
        return proxyTable[_Index][key] 
    end,
    __newindex = function(proxyTable, key, value)
        proxyTable[_Index][key] = value 
    end
}

function _MetaClass:New(...) 
    local instance = {} 
    setmetatable(instance, self) -- 'self' here IS the class table (e.g., OptionsScreenHandler)
    
    local classNameOfClassTable = self._ClassName or "UnknownClassTableInNew"
    Ext.Utils.Print(string.format("[_MetaClass:New] Creating instance of class: '%s'", classNameOfClassTable))

    instance.Class = self -- Store a reference to the CLASS TABLE on the instance
    
    -- Debug: Check what instance.Class points to right after setting it
    local instanceClassNameViaClassField = (instance.Class and instance.Class._ClassName) or "NIL_OR_NO_CLASSNAME_ON_INSTANCE_CLASS"
    Ext.Utils.Print(string.format("[_MetaClass:New for %s] instance.Class._ClassName immediately after assignment: '%s'", classNameOfClassTable, instanceClassNameViaClassField))

    if self.Init and type(self.Init) == "function" then
        if BG3Access and BG3Access.Client and BG3Access.Client.AccessibilityManagerInstance and BG3Access.Client.AccessibilityManagerInstance.config.enableDiagnosticLogging then
            Ext.Utils.Print(string.format("[_MetaClass:New for %s] Before calling instance:Init(...). self.Init is a function.", classNameOfClassTable))
        end
        instance:Init(...) 
        if BG3Access and BG3Access.Client and BG3Access.Client.AccessibilityManagerInstance and BG3Access.Client.AccessibilityManagerInstance.config.enableDiagnosticLogging then
             Ext.Utils.Print(string.format("[_MetaClass:New for %s] After calling instance:Init(...).", classNameOfClassTable))
        end
    else
        Ext.Utils.Print(string.format("[_MetaClass:New for %s] No Init function found on class or not a function.", classNameOfClassTable))
    end
    return instance
end

function _MetaClass:Init()
    -- Default instance initializer.
end

function _MetaClass:_Debug(objectInstance)
    local proxy = {}
    proxy[_Index] = objectInstance
    setmetatable(proxy, _DebugMetaTable)
    return proxy
end

_Class = { 
    Classes = {}
}
_Class.__index = _Class 

function _Class:GetClass(objectOrClassName)
    local className
    if type(objectOrClassName) == "table" then
        local mt = getmetatable(objectOrClassName)
        if mt and mt._ClassName then 
             className = mt._ClassName
        elseif objectOrClassName._ClassName then 
            className = objectOrClassName._ClassName
        end
    elseif type(objectOrClassName) == "string" then
        className = objectOrClassName
    end
    return self.Classes[className]
end

function _Class:GetClassName(objectInstance)
    local mt = getmetatable(objectInstance)
    if mt and mt._ClassName then
        return mt._ClassName
    end
    if objectInstance and objectInstance._ClassName then
        return objectInstance._ClassName
    end
    return nil
end

function _Class:Create(classRegisteredName, parentClassInput, initialMethodsAndProps)
    local newClass = self.Classes[classRegisteredName]
    if newClass == nil then
        newClass = initialMethodsAndProps or {}
        newClass._ClassName = classRegisteredName 
        
        local parentClassObject = nil
        if parentClassInput then
            if type(parentClassInput) == "string" then
                parentClassObject = self.Classes[parentClassInput] 
                if not parentClassObject then
                    Ext.Utils.Print(string.format("[ClassInit CRITICAL] Parent class '%s' not found for creating class '%s'.", parentClassInput, classRegisteredName))
                end
            elseif type(parentClassInput) == "table" and parentClassInput._ClassName then
                parentClassObject = parentClassInput 
            else
                Ext.Utils.Print(string.format("[ClassInit WARNING] Invalid parentClassInput for class '%s'. Type: %s", classRegisteredName, type(parentClassInput)))
            end
        end
        
        if parentClassObject then
            setmetatable(newClass, parentClassObject)
            newClass.ParentClassRef = parentClassObject 
        else
            setmetatable(newClass, _MetaClass)
        end

        newClass.__index = newClass
        
        self.Classes[classRegisteredName] = newClass
        Ext.Utils.Print(string.format("[ClassInit] Class '%s' registered.", classRegisteredName))
    else
        if BG3Access and BG3Access.Client and BG3Access.Client.AccessibilityManagerInstance and BG3Access.Client.AccessibilityManagerInstance.config.enableDiagnosticLogging then
            Ext.Utils.Print(string.format("[ClassInit] Warning: Class '%s' already registered. Returning existing.", classRegisteredName))
        end
    end
    return newClass
end

Ext.Utils.Print("[ClassInit.lua] _MetaClass and _Class defined globally. Added debug in New.")