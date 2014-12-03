/*
 * This file is part of OpenModelica.
 *
 * Copyright (c) 1998-2014, Open Source Modelica Consortium (OSMC),
 * c/o Linköpings universitet, Department of Computer and Information Science,
 * SE-58183 Linköping, Sweden.
 *
 * All rights reserved.
 *
 * THIS PROGRAM IS PROVIDED UNDER THE TERMS OF GPL VERSION 3 LICENSE OR
 * THIS OSMC PUBLIC LICENSE (OSMC-PL) VERSION 1.2.
 * ANY USE, REPRODUCTION OR DISTRIBUTION OF THIS PROGRAM CONSTITUTES
 * RECIPIENT'S ACCEPTANCE OF THE OSMC PUBLIC LICENSE OR THE GPL VERSION 3,
 * ACCORDING TO RECIPIENTS CHOICE.
 *
 * The OpenModelica software and the Open Source Modelica
 * Consortium (OSMC) Public License (OSMC-PL) are obtained
 * from OSMC, either from the above address,
 * from the URLs: http://www.ida.liu.se/projects/OpenModelica or
 * http://www.openmodelica.org, and in the OpenModelica distribution.
 * GNU version 3 is obtained from: http://www.gnu.org/copyleft/gpl.html.
 *
 * This program is distributed WITHOUT ANY WARRANTY; without
 * even the implied warranty of  MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE, EXCEPT AS EXPRESSLY SET FORTH
 * IN THE BY RECIPIENT SELECTED SUBSIDIARY LICENSE CONDITIONS OF OSMC-PL.
 *
 * See the full OSMC Public License conditions for more details.
 *
 */

encapsulated package SimCodeUtil
" file:        SimCodeUtil.mo
  package:     SimCodeUtil
  description: Code generation using Susan templates

  The entry points to this module are the functions createSimCode and
  createFunctions.

  RCS: $Id$"

// public imports
import Absyn;
import BackendDAE;
import Ceval;
import DAE;
import FCore;
import FGraph;
import HashTableExpToIndex;
import HashTableStringToPath;
import SCode;
import Tpl;
import Types;
import Values;
import SimCode;
import SimCodeVar;

// protected imports
protected
import Array;
import BackendDAEOptimize;
import BackendDAETransform;
import BackendDAEUtil;
import BackendDump;
import BackendEquation;
import BackendVariable;
import BackendVarTransform;
import BaseHashTable;
import BaseHashSet;
import Builtin;
import ClockIndexes;
import CevalScript;
import CheckModel;
import ClassInf;
import ComponentReference;
import Config;
import DAEDump;
import DAEUtil;
import Debug;
import Differentiate;
import Error;
import Expression;
import ExpressionDump;
import ExpressionSimplify;
import ExpressionSolve;
import FindZeroCrossings;
import Flags;
import GC;
import Graph;
import HashSet;
import HpcOmSimCode;
import Initialization;
import Inline;
import List;
import Mod;
import PriorityQueue;
import Settings;
import SimCodeDump;
import SymbolicJacobian;
import System;
import Util;
import ValuesUtil;

// =============================================================================
// section for public function for SimCodeTV
//
// =============================================================================

public function elementVars
"Used by templates to get a list of variables from a valueblock."
  input list<DAE.Element> ild;
  output list<SimCode.Variable> vars;
protected
  list<DAE.Element> ld;
algorithm
  ld := List.filter(ild, isVarQ);
  vars := List.map(ld, daeInOutSimVar);
end elementVars;

public function crefSubIsScalar
"Used by templates to determine if a component reference's subscripts are
 scalar."
  input DAE.ComponentRef cref;
  output Boolean isScalar;
protected
  list<DAE.Subscript> subs;
algorithm
  subs := ComponentReference.crefSubs(cref);
  isScalar := subsToScalar(subs);
end crefSubIsScalar;

public function crefNoSub
"Used by templates to determine if a component reference has no subscripts."
  input DAE.ComponentRef cref;
  output Boolean noSub;
algorithm
  noSub := boolNot(ComponentReference.crefHaveSubs(cref));
end crefNoSub;

public function crefIsScalar
  "Whether a component reference is a scalar depends on what context we are in.
  If we are generating code for a function, then only crefs without subscripts
  are scalar. If we are generating code for simulation though, then crefs with
  only constant subscripts are also scalars, since a variable is generated for
  each element of an array in the model."
  input DAE.ComponentRef cref;
  input SimCode.Context context;
  output Boolean isScalar;
algorithm
  isScalar := matchcontinue(cref, context)
    local
      Boolean res;
    case (_, SimCode.FUNCTION_CONTEXT())
      equation
        res = crefNoSub(cref);
      then
        res;
    case (_, SimCode.PARALLEL_FUNCTION_CONTEXT())
      equation
        res = crefNoSub(cref);
      then
        res;
    case (_, _)
      equation
        res = ComponentReference.crefHasScalarSubscripts(cref);
      then
        res;
  end matchcontinue;
end crefIsScalar;

public function buildCrefExpFromAsub
"Used by templates to convert an ASUB expression to a component reference
 with subscripts."
  input DAE.Exp cref;
  input list<DAE.Exp> subs;
  output DAE.Exp cRefOut;
algorithm
  cRefOut := matchcontinue(cref, subs)
    local
      DAE.Exp crefExp;
      DAE.Type ty;
      DAE.ComponentRef crNew;
      list<DAE.Subscript> indexes;

    case (_, {}) then cref;
    case (DAE.CREF(componentRef=crNew, ty=ty), _)
      equation
        indexes = List.map(subs, Expression.makeIndexSubscript);
        crNew = ComponentReference.subscriptCref(crNew, indexes);
        crefExp = Expression.makeCrefExp(crNew, ty);
      then
        crefExp;
  end matchcontinue;
end buildCrefExpFromAsub;

public function incrementInt
"Used by templates to create new integers that are increments of another."
  input Integer inInt;
  input Integer increment;
  output Integer outInt;
algorithm
  outInt := inInt + increment;
end incrementInt;

public function decrementInt
"Used by templates to create new integers that are increments of another."
  input Integer inInt;
  input Integer decrement;
  output Integer outInt;
algorithm
  outInt := inInt - decrement;
end decrementInt;


public function protectedVars
    input list<SimCodeVar.SimVar> InSimVars;
    output list<SimCodeVar.SimVar> OutSimVars;
   algorithm
   OutSimVars:= List.filterOnTrue(InSimVars,isNotProtected);
end protectedVars;

protected function isNotProtected
  input SimCodeVar.SimVar simVar;
  output Boolean isProtected;
algorithm
  SimCodeVar.SIMVAR(isProtected=isProtected) := simVar;
  isProtected := not isProtected;
end isNotProtected;


public function makeCrefRecordExp
"Helper function to generate records."
  input DAE.ComponentRef inCRefRecord;
  input DAE.Var inVar;
  output DAE.Exp outExp;
algorithm
  outExp := match (inCRefRecord, inVar)
    local
      DAE.ComponentRef cr, cr1;
      String name;
      DAE.Type tp;
    case (cr, DAE.TYPES_VAR(name=name, ty=tp))
      equation
        cr1 = ComponentReference.crefPrependIdent(cr, name, {}, tp);
        outExp = Expression.makeCrefExp(cr1, tp);
      then
        outExp;
  end match;
end makeCrefRecordExp;

public function cref2simvar
"Used by templates to find SIMVAR for given cref (to gain representaion index info mainly)."
  input DAE.ComponentRef inCref;
  input SimCode.SimCode simCode;
  output SimCodeVar.SimVar outSimVar;
algorithm
  outSimVar := matchcontinue(inCref, simCode)
    local
      DAE.ComponentRef cref, badcref;
      SimCodeVar.SimVar sv;
      SimCode.HashTableCrefToSimVar crefToSimVarHT;
      String errstr;

    case (cref, SimCode.SIMCODE(crefToSimVarHT = crefToSimVarHT) )
      equation
        sv = get(cref, crefToSimVarHT);
      then sv;

    case (cref, _)
      equation
        badcref = ComponentReference.makeCrefIdent("ERROR_cref2simvar_failed", DAE.T_REAL_DEFAULT, {});
        /* Todo: This also generates an error for example itearation variables, so i commented  out
        "Template did not find the simulation variable for "+ ComponentReference.printComponentRefStr(cref) + ". ";
        Error.addMessage(Error.INTERNAL_ERROR, {errstr});*/
      then
         SimCodeVar.SIMVAR(badcref, BackendDAE.VARIABLE(), "", "", "", -2, NONE(), NONE(), NONE(), NONE(), false, DAE.T_REAL_DEFAULT, false, NONE(), SimCodeVar.NOALIAS(), DAE.emptyElementSource, SimCodeVar.INTERNAL(), NONE(), {}, false, true);
  end matchcontinue;
end cref2simvar;

public function isModelTooBigForCSharpInOneFile
"Used by C# template to determine if the generated code should be split into several files
 to make Visual Studio responsive when the file is opened (C# compiler is OK,
 but VS does not scale well for big C# files)."
  input SimCode.SimCode simCode;
  output Boolean outIsTooBig;
algorithm
  outIsTooBig := match(simCode)
    local
      Integer numAlgVars;

    case (SimCode.SIMCODE(modelInfo = SimCode.MODELINFO(varInfo = SimCode.VARINFO(numAlgVars = numAlgVars))))
      equation
        outIsTooBig = numAlgVars > 1000;
      then outIsTooBig;

  end match;
end isModelTooBigForCSharpInOneFile;

public function derComponentRef
"Used by templates to derrive a cref in a der(cref) expression.
 Particularly, this function is called for the C# code generator,
 while for C/C++, it is solved by prefixing the cref with '$P$DER' in daeExpCall() template.
 The prefixing technique is not usable for C#, because there is no macroprocessor in C#.
 TODO: all der(cref) expressions should be eliminated before the expressions enter templates
       to pull this logic (and this function) out of templates."
  input DAE.ComponentRef inCref;
  output DAE.ComponentRef derCref;
algorithm
  derCref := ComponentReference.crefPrefixDer(inCref);
end derComponentRef;

public function hackArrayReverseToCref
"This is a hack transformation of an expanded array back to its cref.
It is used in daeExpArray() (for C# yet) to optimize the generated code.
TODO: This function should not exist!
Rather the array should not be let expanded when SimCode is entering templates.
"
  input DAE.Exp inExp;
  input SimCode.Context context;
  output DAE.Exp outExp;
algorithm
  outExp := matchcontinue (inExp, context)
    local
      list<DAE.Exp> aRest;
      DAE.ComponentRef cr;
      DAE.Type aty;
      DAE.Exp crefExp;

    case(DAE.ARRAY(ty=aty, scalar=true, array =(DAE.CREF(componentRef=cr) ::aRest)), _)
      equation
        failure(SimCode.FUNCTION_CONTEXT()=context); // only in the function context
        failure(SimCode.PARALLEL_FUNCTION_CONTEXT()=context); // only in the function context
        { DAE.INDEX(DAE.ICONST(1)) } = ComponentReference.crefLastSubs(cr);
        cr = ComponentReference.crefStripLastSubs(cr);
        true = isArrayExpansion(aRest, cr, 2);
        crefExp = Expression.makeCrefExp(cr, aty);
      then
        crefExp;

    case (_, _) then inExp;

  end matchcontinue;
end hackArrayReverseToCref;

protected function isArrayExpansion
"Helper funtion to hackArrayReverseToCref."
  input list<DAE.Exp> inArrayElems;
  input DAE.ComponentRef inCref;
  input Integer index;
  output Boolean isExpanded;
algorithm
  isExpanded := matchcontinue(inArrayElems, inCref, index)
    local
      list<DAE.Exp> aRest;
      Integer i;
      DAE.ComponentRef cr;
    case({}, _, _) then true;
    case (DAE.CREF(componentRef=cr) :: aRest, _, _)
      equation
        { DAE.INDEX(DAE.ICONST(i)) } = ComponentReference.crefLastSubs(cr);
        true = (i == index);
        cr = ComponentReference.crefStripLastSubs(cr);
        true = ComponentReference.crefEqualNoStringCompare(inCref, cr);
      then isArrayExpansion(aRest, inCref, index+1);
    case (_, _, _) then false;
  end matchcontinue;
end isArrayExpansion;

public function hackMatrixReverseToCref
"This is a hack transformation of an expanded matrix back to its cref.
It is used in daeExpMatrix() (for C# yet) to optimize the generated code.
TODO: This function should not exist!
Rather the matrix should not be let expanded when SimCode is entering templates
"
  input DAE.Exp inExp;
  input SimCode.Context context;
  output DAE.Exp outExp;
algorithm
  outExp := matchcontinue (inExp, context)
    local
      DAE.ComponentRef cr;
      DAE.Type aty;
      list<list<DAE.Exp>> rows;
      DAE.Exp crefExp;

    case(DAE.MATRIX(ty=aty, matrix = rows as (((DAE.CREF(componentRef=cr))::_)::_) ), _)
      equation
        failure(SimCode.FUNCTION_CONTEXT()=context);
        failure(SimCode.PARALLEL_FUNCTION_CONTEXT()=context); // only in the function context
        { DAE.INDEX(DAE.ICONST(1)), DAE.INDEX(DAE.ICONST(1)) } = ComponentReference.crefLastSubs(cr);
        cr = ComponentReference.crefStripLastSubs(cr);
        true = isMatrixExpansion(rows, cr, 1, 1);
        crefExp = Expression.makeCrefExp(cr, aty);
      then
        crefExp;

    case (_, _) then inExp;

  end matchcontinue;
end hackMatrixReverseToCref;

protected function isMatrixExpansion
"Helper funtion to hackMatrixReverseToCref."
  input list<list<DAE.Exp>> rows;
  input DAE.ComponentRef inCref;
  input Integer rowIndex;
  input Integer colIndex;
  output Boolean isExpanded;
algorithm
  isExpanded := matchcontinue(rows, inCref, rowIndex, colIndex)
    local
      list<list<DAE.Exp>> restRows;
      list<DAE.Exp> restElems;
      Integer r, c;
      DAE.ComponentRef cr;
    case({}, _, _, _) then true;
    case({} :: restRows, _, _, _) then isMatrixExpansion(restRows, inCref, rowIndex+1, 1);
    case ( (DAE.CREF(componentRef=cr) :: restElems) :: restRows, _, _, _)
      equation
        { DAE.INDEX(DAE.ICONST(r)), DAE.INDEX(DAE.ICONST(c)) } = ComponentReference.crefLastSubs(cr);
        true = (r == rowIndex) and (c == colIndex);
        cr = ComponentReference.crefStripLastSubs(cr);
        true = ComponentReference.crefEqualNoStringCompare(inCref, cr);
      then isMatrixExpansion(restElems :: restRows, inCref, rowIndex, colIndex+1);
    else false;
  end matchcontinue;
end isMatrixExpansion;

public function hackGetFirstExternalFunctionLib
"This is a hack to get the original library name given to an external function.
TODO: redesign OMC and Modelica specification so they are not so C/C++ centric."
  input list<String> libs;
  output String outFirstLib;
algorithm
  outFirstLib := matchcontinue (libs)
    local
      String lib;

    case _
      equation
        lib = List.last(libs);
        lib = System.stringReplace(lib, "-l", "");
      then
        lib;

    case(_) then "NO_LIB";

  end matchcontinue;
end hackGetFirstExternalFunctionLib;

public function createAssertforSqrt
   input DAE.Exp inExp;
   output DAE.Exp outExp;
algorithm
  outExp :=
  match (inExp)
    case(_)
      equation
        // Simplify things like abs(exp) >= 0 to exp
        (outExp, _) = ExpressionSimplify.simplify(DAE.RELATION(inExp, DAE.GREATEREQ(DAE.T_REAL_DEFAULT), DAE.RCONST(0.0), -1, NONE()));
      then outExp;
  end match;
end createAssertforSqrt;

public function createDAEString
   input String inString;
   output DAE.Exp outExp;
   annotation(__OpenModelica_EarlyInline = true);
algorithm
  outExp := DAE.SCONST(inString);
end createDAEString;

public function appendLists
  input list<SimCode.SimEqSystem> inEqn1;
  input list<SimCode.SimEqSystem> inEqn2;
  output list<SimCode.SimEqSystem> outEqn;
algorithm
  outEqn := listAppend(inEqn1, inEqn2);
end appendLists;

protected function compareEqSystems
  input SimCode.SimEqSystem eq1;
  input SimCode.SimEqSystem eq2;
  output Boolean b;
algorithm
  b := eqIndex(eq1) > eqIndex(eq2);
end compareEqSystems;

public function sortEqSystems
  input list<SimCode.SimEqSystem> eqs;
  output list<SimCode.SimEqSystem> outEqs;
algorithm
  outEqs := List.sort(eqs,compareEqSystems);
end sortEqSystems;

/** end of TypeView published functions **/

// =============================================================================
// section to generate SimCode from functions
//
// Finds the called functions in BackendDAE and transforms them to a list of
// libraries and a list of SimCode.Function uniontypes.
// =============================================================================

public function createFunctions
  input Absyn.Program inProgram;
  input DAE.DAElist inDAElist;
  input BackendDAE.BackendDAE inBackendDAE;
  input Absyn.Path inPath;
  output list<String> libs;
  output list<String> libPaths;
  output list<String> includes;
  output list<String> includeDirs;
  output list<SimCode.RecordDeclaration> recordDecls;
  output list<SimCode.Function> functions;
  output BackendDAE.BackendDAE outBackendDAE;
  output DAE.DAElist outDAE;
  output tuple<Integer, HashTableExpToIndex.HashTable, list<DAE.Exp>> literals;
algorithm
  (libs,libPaths, includes, includeDirs, recordDecls, functions, outBackendDAE, outDAE, literals) :=
  matchcontinue (inProgram, inDAElist, inBackendDAE, inPath)
    local
      list<String> libs2,libpaths2, includes2, includeDirs2;
      list<DAE.Function> funcelems, part_func_elems, recFuncs;
      DAE.DAElist dae;
      BackendDAE.BackendDAE dlow;
      DAE.FunctionTree functionTree;
      Absyn.Path path;
      list<SimCode.Function> fns;
      list<DAE.Exp> lits;

    case (_, dae, dlow as BackendDAE.DAE(shared=BackendDAE.SHARED(functionTree=functionTree)), _)
      equation
        // get all the used functions from the function tree
        funcelems = DAEUtil.getFunctionList(functionTree);
        funcelems = setRecordVariability(funcelems,inBackendDAE);
        funcelems = Inline.inlineCallsInFunctions(funcelems, (NONE(), {DAE.NORM_INLINE(), DAE.AFTER_INDEX_RED_INLINE()}), {});
        (funcelems, literals as (_, _, lits)) = simulationFindLiterals(dlow, funcelems);
        (fns, recordDecls, includes2, includeDirs2, libs2,libpaths2) = elaborateFunctions(inProgram, funcelems, {}, lits, {}); // Do we need metarecords here as well?
      then
        (libs2, libpaths2,includes2, includeDirs2, recordDecls, fns, dlow, dae, literals);
    else
      equation
        Error.addMessage(Error.INTERNAL_ERROR, {"Creation of Modelica functions failed. "});
      then
        fail();
  end matchcontinue;
end createFunctions;

protected function orderRecordDecls
  input SimCode.RecordDeclaration decl1;
  input SimCode.RecordDeclaration decl2;
  output Boolean b;
algorithm
  b := match (decl1,decl2)
    local
      Absyn.Path path1,path2;
    case (SimCode.RECORD_DECL_DEF(path=path1),SimCode.RECORD_DECL_DEF(path=path2)) then Absyn.pathGe(path1,path2);
    else true;
  end match;
end orderRecordDecls;

public function elaborateFunctions
  input Absyn.Program program;
  input list<DAE.Function> daeElements;
  input list<DAE.Type> metarecordTypes;
  input list<DAE.Exp> literals;
  input list<String> includes;
  output list<SimCode.Function> functions;
  output list<SimCode.RecordDeclaration> extraRecordDecls;
  output list<String> outIncludes;
  output list<String> includeDirs;
  output list<String> libs;
  output list<String> libpaths;
protected
  list<SimCode.Function> fns;
  list<String> outRecordTypes;
  HashTableStringToPath.HashTable ht;
  list<tuple<SimCode.RecordDeclaration,list<SimCode.RecordDeclaration>>> g;
algorithm
  (extraRecordDecls, outRecordTypes) := elaborateRecordDeclarationsForMetarecords(literals, {}, {});
  (functions, outRecordTypes, extraRecordDecls, outIncludes, includeDirs, libs,libpaths) := elaborateFunctions2(program, daeElements, {}, outRecordTypes, extraRecordDecls, includes, {}, {},{});
  extraRecordDecls := List.unique(extraRecordDecls);
  (extraRecordDecls, _) := elaborateRecordDeclarationsFromTypes(metarecordTypes, extraRecordDecls, outRecordTypes);
  extraRecordDecls := List.sort(extraRecordDecls, orderRecordDecls);
  ht := HashTableStringToPath.emptyHashTableSized(BaseHashTable.lowBucketSize);
  (extraRecordDecls,_) := List.mapFold(extraRecordDecls, aliasRecordDeclarations, ht);
  // Topological sort since we have no guarantees in the order of generated records
  g := Graph.buildGraph(extraRecordDecls, getRecordDependencies, extraRecordDecls);
  (extraRecordDecls, {}) := Graph.topologicalSort(g, isRecordDeclEqual);
end elaborateFunctions;

protected function getRecordDependencies
  input SimCode.RecordDeclaration decl;
  input list<SimCode.RecordDeclaration> allDecls;
  output list<SimCode.RecordDeclaration> dependencies;
algorithm
  dependencies := match (decl,allDecls)
    local
      String name;
      list<SimCode.Variable> vars;
      list<DAE.Type> tys;
      list<list<DAE.Type>> tyss;
    case (SimCode.RECORD_DECL_FULL(aliasName=SOME(name)),_)
      then List.select1(allDecls, isRecordDecl, name);
    case (SimCode.RECORD_DECL_FULL(variables=vars),_)
      equation
        tys = List.map(vars, getVarType);
        tyss = List.map1(tys, Types.getAllInnerTypesOfType, Util.anyReturnTrue);
        tys = List.flatten(tyss);
        dependencies = List.filterMap1(tys, getRecordDependenciesFromType, allDecls);
      then List.unique(dependencies);
    else {};
  end match;
end getRecordDependencies;

protected function getVarType
  input SimCode.Variable var;
  output DAE.Type ty;
algorithm
  ty := match var
    case SimCode.VARIABLE(ty=ty) then ty;
    else DAE.T_ANYTYPE_DEFAULT;
  end match;
end getVarType;

protected function getRecordDependenciesFromType
  input DAE.Type ty;
  input list<SimCode.RecordDeclaration> allDecls;
  output SimCode.RecordDeclaration decl;
protected
  Absyn.Path path;
  String name;
algorithm
  DAE.T_COMPLEX(complexClassType = ClassInf.RECORD(path)) := ty;
  name := Absyn.pathStringUnquoteReplaceDot(path, "_");
  decl := List.selectFirst1(allDecls, isRecordDecl, name);
end getRecordDependenciesFromType;

protected function isRecordDecl
  input SimCode.RecordDeclaration decl;
  input String name;
  output Boolean b;
algorithm
  b := match (decl,name)
    local
      String name1;
    case (SimCode.RECORD_DECL_FULL(name=name1),_) then stringEq(name,name1);
    else false;
  end match;
end isRecordDecl;

protected function isRecordDeclEqual
  input SimCode.RecordDeclaration decl1;
  input SimCode.RecordDeclaration decl2;
  output Boolean b;
algorithm
  b := match (decl1,decl2)
    local
      String name1,name2;
      Absyn.Path path1,path2;
    case (SimCode.RECORD_DECL_FULL(name=name1),SimCode.RECORD_DECL_FULL(name=name2)) then stringEq(name1,name2);
    case (SimCode.RECORD_DECL_DEF(path=path1),SimCode.RECORD_DECL_DEF(path=path2)) then Absyn.pathEqual(path1,path2);
    else false;
  end match;
end isRecordDeclEqual;

protected function elaborateFunctions2
  input Absyn.Program program;
  input list<DAE.Function> daeElements;
  input list<SimCode.Function> inFunctions;
  input list<String> inRecordTypes;
  input list<SimCode.RecordDeclaration> inDecls;
  input list<String> inIncludes;
  input list<String> inIncludeDirs;
  input list<String> inLibs;
  input list<String> inPaths;
  output list<SimCode.Function> outFunctions;
  output list<String> outRecordTypes;
  output list<SimCode.RecordDeclaration> outDecls;
  output list<String> outIncludes;
  output list<String> outIncludeDirs;
  output list<String> outLibs;
  output list<String> outLibsPaths;
algorithm
  (outFunctions, outRecordTypes, outDecls, outIncludes, outIncludeDirs, outLibs,outLibsPaths) :=
  match (program, daeElements, inFunctions, inRecordTypes, inDecls, inIncludes, inIncludeDirs, inLibs,inPaths)
    local
      Boolean b;
      list<SimCode.Function> accfns, fns;
      SimCode.Function fn;
      list<String> rt, rt_1, rt_2, includes, libs,libPaths;
      DAE.Function fel;
      list<DAE.Function> rest;
      list<SimCode.RecordDeclaration> decls;
      String name;
      list<String> includeDirs;
      Absyn.Path path;

    case (_, {}, accfns, rt, decls, includes, includeDirs, libs,libPaths)
    then (listReverse(accfns), rt, decls, includes, includeDirs, libs,libPaths);
    case (_, (DAE.FUNCTION( type_ = DAE.T_FUNCTION(functionAttributes=DAE.FUNCTION_ATTRIBUTES(isBuiltin=DAE.FUNCTION_BUILTIN_PTR()))) :: rest), accfns, rt, decls, includes, includeDirs, libs,libPaths)
      equation
        // skip over builtin functions
        (fns, rt_2, decls, includes, includeDirs, libs,libPaths) = elaborateFunctions2(program, rest, accfns, rt, decls, includes, includeDirs, libs,libPaths);
      then
        (fns, rt_2, decls, includes, includeDirs, libs,libPaths);
    case (_, (DAE.FUNCTION(partialPrefix = true) :: rest), accfns, rt, decls, includes, includeDirs, libs,libPaths)
      equation
        // skip over partial functions
        (fns, rt_2, decls, includes, includeDirs, libs,libPaths) = elaborateFunctions2(program, rest, accfns, rt, decls, includes, includeDirs, libs,libPaths);
      then
        (fns, rt_2, decls, includes, includeDirs, libs,libPaths);
    case (_, DAE.FUNCTION(functions = DAE.FUNCTION_EXT(externalDecl = DAE.EXTERNALDECL(language="builtin"))::_)::rest, accfns, rt, decls, includes, includeDirs, libs,libPaths)
      equation
        // skip over builtin functions
        (fns, rt_2, decls, includes, includeDirs, libs,libPaths) = elaborateFunctions2(program, rest, accfns, rt, decls, includes, includeDirs, libs,libPaths);
      then
        (fns, rt_2, decls, includes, includeDirs, libs,libPaths);

    case (_, (fel as DAE.FUNCTION(functions = DAE.FUNCTION_EXT(externalDecl = DAE.EXTERNALDECL(name=name, language="C"))::_))::rest, accfns, rt, decls, includes, includeDirs, libs,libPaths)
      equation
        // skip over builtin functions
        b = listMember(name, SCode.knownExternalCFunctions);
        (fn,_, decls, includes, includeDirs, libs,libPaths) = elaborateFunction(program, fel, rt, decls, includes, includeDirs, libs,libPaths);
        (fns, rt_2, decls, includes, includeDirs, libs,libPaths) = elaborateFunctions2(program, rest, List.consOnTrue(not b, fn, accfns), rt, decls, includes, includeDirs, libs,libPaths);
      then
        (fns, rt_2, decls, includes, includeDirs, libs,libPaths);

    case (_, (fel :: rest), accfns, rt, decls, includes, includeDirs, libs,libPaths)
      equation
        (fn, rt_1, decls, includes, includeDirs, libs,libPaths) = elaborateFunction(program, fel, rt, decls, includes, includeDirs, libs,libPaths);
        (fns, rt_2, decls, includes, includeDirs, libs,libPaths) = elaborateFunctions2(program, rest, (fn :: accfns), rt_1, decls, includes, includeDirs, libs,libPaths);
      then
        (fns, rt_2, decls, includes, includeDirs, libs,libPaths);
  end match;
end elaborateFunctions2;

/* Does the actual work of transforming a DAE.FUNCTION to a SimCode.Function. */
protected function elaborateFunction
  input Absyn.Program program;
  input DAE.Function inElement;
  input list<String> inRecordTypes;
  input list<SimCode.RecordDeclaration> inRecordDecls;
  input list<String> inIncludes;
  input list<String> inIncludeDirs;
  input list<String> inLibs;
  input list<String> inLibPaths;
  output SimCode.Function outFunction;
  output list<String> outRecordTypes;
  output list<SimCode.RecordDeclaration> outRecordDecls;
  output list<String> outIncludes;
  output list<String> outIncludeDirs;
  output list<String> outLibs;
  output list<String> outLibPaths;
algorithm
  (outFunction, outRecordTypes, outRecordDecls, outIncludes, outIncludeDirs, outLibs,outLibPaths):=
  matchcontinue (program, inElement, inRecordTypes, inRecordDecls, inIncludes, inIncludeDirs, inLibs,inLibPaths)
    local
      DAE.Function fn;
      String extfnname, lang, str;
      list<DAE.Element> algs, vars; // , bivars, invars, outvars;
      list<String> includes, libs, libPaths, fn_libs,fn_paths, fn_includes, fn_includeDirs, rt, rt_1;
      Absyn.Path fpath;
      list<DAE.FuncArg> args;
      DAE.Type restype, tp;
      list<DAE.ExtArg> extargs;
      list<SimCode.SimExtArg> simextargs;
      SimCode.SimExtArg extReturn;
      DAE.ExtArg extretarg;
      Option<SCode.Annotation> ann;
      DAE.ExternalDecl extdecl;
      list<SimCode.Variable> outVars, inVars, biVars, funArgs, varDecls;
      list<SimCode.RecordDeclaration> recordDecls;
      list<SimCode.Statement> bodyStmts;
      list<DAE.Element> daeElts;
      Absyn.Path name;
      DAE.ElementSource source;
      SourceInfo info;
      Boolean dynamicLoad, hasIncludeAnnotation, hasLibraryAnnotation;
      list<String> includeDirs;
      DAE.FunctionAttributes funAttrs;
      list<DAE.Var> varlst;
      DAE.VarKind kind;
      SCode.Visibility visibility;

      // Modelica functions.
    case (_, DAE.FUNCTION(path = fpath, source = source, visibility = visibility,
      functions = DAE.FUNCTION_DEF(body = daeElts)::_, // might be followed by derivative maps
      type_ = DAE.T_FUNCTION(funcArg=args, functionAttributes=funAttrs),
      partialPrefix=false), rt, recordDecls, includes, includeDirs, libs,libPaths)
      equation

        DAE.FUNCTION_ATTRIBUTES(functionParallelism=DAE.FP_NON_PARALLEL()) = funAttrs;

        outVars = List.map(DAEUtil.getOutputVars(daeElts), daeInOutSimVar);
        funArgs = List.map1(args, typesSimFunctionArg, NONE());
        (recordDecls, rt_1) = elaborateRecordDeclarations(daeElts, recordDecls, rt);
        vars = List.filter(daeElts, isVarQ);
        varDecls = List.map(vars, daeInOutSimVar);
        algs = List.filterOnTrue(daeElts, DAEUtil.isAlgorithm);
        bodyStmts = List.map(algs, elaborateStatement);
        info = DAEUtil.getElementSourceFileInfo(source);
      then
        (SimCode.FUNCTION(fpath, outVars, funArgs, varDecls, bodyStmts, visibility, info), rt_1, recordDecls, includes, includeDirs, libs,libPaths);


     case (_, DAE.FUNCTION(path = fpath, source = source,
      functions = DAE.FUNCTION_DEF(body = daeElts)::_, // might be followed by derivative maps
      type_ = DAE.T_FUNCTION(funcArg=args, functionAttributes=funAttrs),
      partialPrefix=false), rt, recordDecls, includes, includeDirs, libs,libPaths)
      equation

        DAE.FUNCTION_ATTRIBUTES(functionParallelism=DAE.FP_KERNEL_FUNCTION()) = funAttrs;

        outVars = List.map(DAEUtil.getOutputVars(daeElts), daeInOutSimVar);
        funArgs = List.map1(args, typesSimFunctionArg, NONE());
        (recordDecls, rt_1) = elaborateRecordDeclarations(daeElts, recordDecls, rt);
        vars = List.filter(daeElts, isVarNotInputNotOutput);
        varDecls = List.map(vars, daeInOutSimVar);
        algs = List.filterOnTrue(daeElts, DAEUtil.isAlgorithm);
        bodyStmts = List.map(algs, elaborateStatement);
        info = DAEUtil.getElementSourceFileInfo(source);
      then
        (SimCode.KERNEL_FUNCTION(fpath, outVars, funArgs, varDecls, bodyStmts, info), rt_1, recordDecls, includes, includeDirs, libs,libPaths);


    case (_, DAE.FUNCTION(path = fpath, source = source,
      functions = DAE.FUNCTION_DEF(body = daeElts)::_, // might be followed by derivative maps
      type_ = DAE.T_FUNCTION(funcArg=args, functionAttributes = funAttrs),
      partialPrefix=false), rt, recordDecls, includes, includeDirs, libs,libPaths)
      equation

        DAE.FUNCTION_ATTRIBUTES(functionParallelism=DAE.FP_PARALLEL_FUNCTION()) = funAttrs;

        outVars = List.map(DAEUtil.getOutputVars(daeElts), daeInOutSimVar);
        funArgs = List.map1(args, typesSimFunctionArg, NONE());
        (recordDecls, rt_1) = elaborateRecordDeclarations(daeElts, recordDecls, rt);
        vars = List.filter(daeElts, isVarQ);
        varDecls = List.map(vars, daeInOutSimVar);
        algs = List.filterOnTrue(daeElts, DAEUtil.isAlgorithm);
        bodyStmts = List.map(algs, elaborateStatement);
        info = DAEUtil.getElementSourceFileInfo(source);
      then
        (SimCode.PARALLEL_FUNCTION(fpath, outVars, funArgs, varDecls, bodyStmts, info), rt_1, recordDecls, includes, includeDirs, libs,libPaths);

    // External functions.
    case (_, DAE.FUNCTION(path = fpath, source = source, visibility = visibility,
      functions = DAE.FUNCTION_EXT(body =  daeElts, externalDecl = extdecl)::_, // might be followed by derivative maps
      type_ = (DAE.T_FUNCTION(funcArg = args))), rt, recordDecls, includes, includeDirs, libs,libPaths)
      equation
        DAE.EXTERNALDECL(name=extfnname, args=extargs,
          returnArg=extretarg, language=lang, ann=ann) = extdecl;
        // outvars = DAEUtil.getOutputVars(daeElts);
        // invars = DAEUtil.getInputVars(daeElts);
        // bivars = DAEUtil.getBidirVars(daeElts);
        funArgs = List.map1(args, typesSimFunctionArg, NONE());
        outVars = List.map(DAEUtil.getOutputVars(daeElts), daeInOutSimVar);
        inVars = List.map(DAEUtil.getInputVars(daeElts), daeInOutSimVar);
        biVars = List.map(DAEUtil.getBidirVars(daeElts), daeInOutSimVar);
        (recordDecls, rt_1) = elaborateRecordDeclarations(daeElts, recordDecls, rt);
        (fn_includes, fn_includeDirs, fn_libs, fn_paths,dynamicLoad) = generateExtFunctionIncludes(program, fpath, ann);
        includes = List.union(fn_includes, includes);
        includeDirs = List.union(fn_includeDirs, includeDirs);
        libs = List.union(fn_libs, libs);
        libPaths = List.union(fn_paths, libPaths);
        simextargs = List.map(extargs, extArgsToSimExtArgs);
        extReturn = extArgsToSimExtArgs(extretarg);
        (simextargs, extReturn) = fixOutputIndex(outVars, simextargs, extReturn);
        info = DAEUtil.getElementSourceFileInfo(source);
        // make lang to-upper as we have FORTRAN 77 and Fortran 77 in the Modelica Library!
        lang = System.toupper(lang);
      then
        (SimCode.EXTERNAL_FUNCTION(fpath, extfnname, funArgs, simextargs, extReturn,
          inVars, outVars, biVars, fn_includes, fn_libs, lang, visibility, info, dynamicLoad),
          rt_1, recordDecls, includes, includeDirs, libs,libPaths);

        // Record constructor.
    case (_, DAE.RECORD_CONSTRUCTOR(source = source, type_ = DAE.T_FUNCTION(funcArg = args, funcResultType = restype as DAE.T_COMPLEX(complexClassType = ClassInf.RECORD(name))),kind=kind), rt, recordDecls, includes, includeDirs, libs,libPaths)
      equation
        funArgs = List.map1(args, typesSimFunctionArg, NONE());
        (recordDecls, rt_1) = elaborateRecordDeclarationsForRecord(restype, recordDecls, rt);
        DAE.T_COMPLEX(varLst = varlst) = restype;
        varlst = List.filterOnTrue(varlst, Types.isProtectedVar);
        varDecls = List.map(varlst, typesVar);
        info = DAEUtil.getElementSourceFileInfo(source);
      then
        (SimCode.RECORD_CONSTRUCTOR(name, funArgs, varDecls, SCode.PUBLIC(), info, kind), rt_1, recordDecls, includes, includeDirs, libs,libPaths);

        // failure
    case (_, fn, _, _, _, _, _,_)
      equation
        Error.addInternalError("function elaborateFunction failed for function: \n" + DAEDump.dumpFunctionStr(fn), sourceInfo());
      then
        fail();
  end matchcontinue;
end elaborateFunction;

protected function typesSimFunctionArg
"Generates code from a function argument."
  input DAE.FuncArg inFuncArg;
  input Option<DAE.Exp> binding;
  output SimCode.Variable outVar;
algorithm
  outVar := matchcontinue (inFuncArg, binding)
    local
      DAE.Type tty;
      String name;
      DAE.ComponentRef cref_;
      DAE.Const const;
      list<DAE.FuncArg> args;
      DAE.Type res_ty;
      list<SimCode.Variable> var_args;
      list<DAE.Type> tys;
      DAE.VarKind kind;
      DAE.VarParallelism prl;

    case (DAE.FUNCARG(name=name, ty=DAE.T_FUNCTION(funcArg = args, funcResultType = DAE.T_TUPLE(types = tys))), _)
      equation
        var_args = List.map1(args, typesSimFunctionArg, NONE());
        tys = List.map(tys, Types.simplifyType);
      then
        SimCode.FUNCTION_PTR(name, tys, var_args, binding);

    case (DAE.FUNCARG(name=name, ty=DAE.T_FUNCTION(funcArg = args, funcResultType = DAE.T_NORETCALL())), _)
      equation
        var_args = List.map1(args, typesSimFunctionArg, NONE());
      then
        SimCode.FUNCTION_PTR(name, {}, var_args, binding);

    case (DAE.FUNCARG(name=name, ty=DAE.T_FUNCTION(funcArg = args, funcResultType = res_ty)), _)
      equation
        res_ty = Types.simplifyType(res_ty);
        var_args = List.map1(args, typesSimFunctionArg, NONE());
      then
        SimCode.FUNCTION_PTR(name, {res_ty}, var_args, binding);

    case (DAE.FUNCARG(name=name, ty=tty, par=prl, const=const), _)
      equation
        tty = Types.simplifyType(tty);
        cref_  = ComponentReference.makeCrefIdent(name, tty, {});
        kind = DAEUtil.const2VarKind(const);
      then
        SimCode.VARIABLE(cref_, tty, binding, {}, prl, kind);
  end matchcontinue;
end typesSimFunctionArg;

protected function daeInOutSimVar
  input DAE.Element inElement;
  output SimCode.Variable outVar;
algorithm
  outVar := matchcontinue(inElement)
    local
      String name;
      DAE.Type daeType;
      DAE.ComponentRef id;
      DAE.VarKind kind;
      DAE.VarParallelism prl;
      list<DAE.Dimension> inst_dims;
      list<DAE.Exp> inst_dims_exp;
      Option<DAE.Exp> binding;
      SimCode.Variable var;
    case (DAE.VAR(componentRef = DAE.CREF_IDENT(ident=name), ty = daeType as DAE.T_FUNCTION(), parallelism = prl, binding = binding))
      equation
        var = typesSimFunctionArg(DAE.FUNCARG(name, daeType, DAE.C_VAR(), prl, NONE()), binding);
      then var;

    case (DAE.VAR(componentRef = id,
      parallelism = prl,
      ty = daeType,
      binding = binding,
      dims = inst_dims,
      kind = kind
    ))
      equation
        daeType = Types.simplifyType(daeType);
        inst_dims_exp = List.map(inst_dims, Expression.dimensionSizeExpHandleUnkown);
      then SimCode.VARIABLE(id, daeType, binding, inst_dims_exp, prl, kind);
    case (_)
      equation
        // TODO: ArrayEqn fails here
        Error.addInternalError("function daeInOutSimVar failed\n", sourceInfo());
      then
        fail();
  end matchcontinue;
end daeInOutSimVar;

protected function extArgsToSimExtArgs
  input DAE.ExtArg extArg;
  output SimCode.SimExtArg simExtArg;
algorithm
  simExtArg :=
  match (extArg)
    local
      DAE.ComponentRef componentRef;
      DAE.Attributes attributes;
      DAE.Type type_;
      Boolean isInput;
      Boolean isOutput;
      Boolean isArray;
      DAE.Exp exp_;
      Integer outputIndex;

    case DAE.EXTARG(componentRef, attributes, type_)
      equation
        isInput = Types.isInputAttr(attributes);
        isOutput = Types.isOutputAttr(attributes);
        outputIndex = if isOutput then -1 else 0; // correct output index is added later by fixOutputIndex
        isArray = Types.isArray(type_, {});
        type_ = Types.simplifyType(type_);
      then SimCode.SIMEXTARG(componentRef, isInput, outputIndex, isArray, false /*fixed later*/, type_);

    case DAE.EXTARGEXP(exp_, type_)
      equation
        type_ = Types.simplifyType(type_);
      then SimCode.SIMEXTARGEXP(exp_, type_);

    case DAE.EXTARGSIZE(componentRef, attributes, type_, exp_)
      equation
        isInput = Types.isInputAttr(attributes);
        isOutput = Types.isOutputAttr(attributes);
        outputIndex = if isOutput then -1 else 0; // correct output index is added later by fixOutputIndex
        type_ = Types.simplifyType(type_);
      then SimCode.SIMEXTARGSIZE(componentRef, isInput, outputIndex, type_, exp_);

    case DAE.NOEXTARG() then SimCode.SIMNOEXTARG();
  end match;
end extArgsToSimExtArgs;

protected function fixOutputIndex
  input list<SimCode.Variable> outVars;
  input list<SimCode.SimExtArg> simExtArgsIn;
  input SimCode.SimExtArg extReturnIn;
  output list<SimCode.SimExtArg> simExtArgsOut;
  output SimCode.SimExtArg extReturnOut;
algorithm
  (simExtArgsOut, extReturnOut) := match (outVars, simExtArgsIn, extReturnIn)
    local
    case (_, _, _)
      equation
        simExtArgsOut = List.map1(simExtArgsIn, assignOutputIndex, outVars);
        extReturnOut = assignOutputIndex(extReturnIn, outVars);
      then
        (simExtArgsOut, extReturnOut);
  end match;
end fixOutputIndex;

protected function assignOutputIndex
  input SimCode.SimExtArg simExtArgIn;
  input list<SimCode.Variable> outVars;
  output SimCode.SimExtArg simExtArgOut;
algorithm
  simExtArgOut :=
  matchcontinue (simExtArgIn, outVars)
    local
      DAE.ComponentRef cref, fcref;
      Boolean isInput;
      Integer outputIndex; // > 0 if output
      Boolean isArray, hasBinding;
      DAE.Type type_;
      DAE.Exp exp;
      Integer newOutputIndex;

    case (SimCode.SIMEXTARG(cref, isInput, outputIndex, isArray, _, type_), _)
      equation
        true = outputIndex == -1;
        fcref = ComponentReference.crefFirstCref(cref);
        (newOutputIndex, hasBinding) = findIndexInList(fcref, outVars, 1);
      then
        SimCode.SIMEXTARG(cref, isInput, newOutputIndex, isArray, hasBinding, type_);

    case (SimCode.SIMEXTARGSIZE(cref, isInput, outputIndex, type_, exp), _)
      equation
        true = outputIndex == -1;
        (newOutputIndex, _) = findIndexInList(cref, outVars, 1);
      then
        SimCode.SIMEXTARGSIZE(cref, isInput, newOutputIndex, type_, exp);

    case (_, _)
      then
        simExtArgIn;
  end matchcontinue;
end assignOutputIndex;

protected function findIndexInList
  input DAE.ComponentRef cref;
  input list<SimCode.Variable> outVars;
  input Integer inCurrentIndex;
  output Integer crefIndexInOutVars;
  output Boolean hasBinding;
algorithm
  (crefIndexInOutVars, hasBinding) :=
  matchcontinue (cref, outVars, inCurrentIndex)
    local
      DAE.ComponentRef name;
      list<SimCode.Variable> restOutVars;
      Option<DAE.Exp> v;
      Integer currentIndex;

    case (_, {}, _) then (-1, false);
    case (_, SimCode.VARIABLE(name=name, value=v) :: _, currentIndex)
      equation
        true = ComponentReference.crefEqualNoStringCompare(cref, name);
      then (currentIndex, Util.isSome(v));
    case (_, _ :: restOutVars, currentIndex)
      equation
        currentIndex = currentIndex + 1;
        (currentIndex, hasBinding) = findIndexInList(cref, restOutVars, currentIndex);
      then (currentIndex, hasBinding);
  end matchcontinue;
end findIndexInList;

protected function elaborateStatement
  input DAE.Element inElement;
  output SimCode.Statement outStatement;
algorithm
  (outStatement):=
  matchcontinue (inElement)
    local
      list<DAE.Statement> stmts;
    case (DAE.ALGORITHM(algorithm_ = DAE.ALGORITHM_STMTS(statementLst = stmts)))
    then
      SimCode.ALGORITHM(stmts);
    case (_)
      equation
        true = Flags.isSet(Flags.FAILTRACE);
        Debug.trace("# SimCode.elaborateStatement failed\n");
      then
        fail();
  end matchcontinue;
end elaborateStatement;


public function checkValidMainFunction
"Verifies that an in-function can be generated.
This is not the case if the input involves function-pointers."
  input String name;
  input SimCode.Function fn;
algorithm
  _ := matchcontinue (name, fn)
    local
      list<SimCode.Variable> inVars;
    case (_, SimCode.FUNCTION(functionArguments = inVars))
      equation
        failure(_ = List.selectFirst(inVars, isFunctionPtr));
      then ();
    case (_, SimCode.EXTERNAL_FUNCTION(inVars = inVars))
      equation
        failure(_ = List.selectFirst(inVars, isFunctionPtr));
      then ();
    case (_, _)
      equation
        Error.addMessage(Error.GENERATECODE_INVARS_HAS_FUNCTION_PTR, {name});
      then fail();
  end matchcontinue;
end checkValidMainFunction;

public function isBoxedFunction
"Verifies that an in-function can be generated.
This is not the case if the input involves function-pointers."
  input SimCode.Function fn;
  output Boolean b;
algorithm
  b := matchcontinue fn
    local
      list<SimCode.Variable> inVars, outVars;
    case (SimCode.FUNCTION(functionArguments = inVars, outVars = outVars))
      equation
        List.map_0(inVars, isBoxedArg);
        List.map_0(outVars, isBoxedArg);
      then true;
    case (SimCode.EXTERNAL_FUNCTION(inVars = inVars, outVars = outVars))
      equation
        List.map_0(inVars, isBoxedArg);
        List.map_0(outVars, isBoxedArg);
      then true;
    else false;
  end matchcontinue;
end isBoxedFunction;

protected function isFunctionPtr
"Checks if an input variable is a function pointer"
  input SimCode.Variable var;
  output Boolean b;
algorithm
  b := matchcontinue var
    local
      /* Yes, they are VARIABLE, not SimCode.FUNCTION_PTR. */
    case SimCode.FUNCTION_PTR()
    then true;
    case _ then false;
  end matchcontinue;
end isFunctionPtr;

protected function isBoxedArg
"Checks if a variable is a boxed datatype"
  input SimCode.Variable var;
algorithm
  _ := match var
    case SimCode.FUNCTION_PTR() then ();
    case SimCode.VARIABLE(ty = DAE.T_METABOXED()) then ();
    case SimCode.VARIABLE(ty = DAE.T_METATYPE()) then ();
    case SimCode.VARIABLE(ty = DAE.T_STRING()) then ();
  end match;
end isBoxedArg;

// =============================================================================
// section of literals translation SimCode
//
// =============================================================================

public function findLiterals
  "Finds all literal expressions in functions"
  input list<DAE.Function> fns;
  output list<DAE.Function> ofns;
  output list<DAE.Exp> literals;
algorithm
  (ofns, (_, _, literals)) := DAEUtil.traverseDAEFunctions(
    fns, findLiteralsHelper,
    (0, HashTableExpToIndex.emptyHashTableSized(BaseHashTable.bigBucketSize), {}), {});
  literals := listReverse(literals);
end findLiterals;

protected function simulationFindLiterals
  "Finds all literal expressions in the DAE"
  input BackendDAE.BackendDAE dae;
  input list<DAE.Function> fns;
  output list<DAE.Function> ofns;
  output tuple<Integer, HashTableExpToIndex.HashTable, list<DAE.Exp>> literals;
algorithm
  (ofns, literals) := DAEUtil.traverseDAEFunctions(
    fns, findLiteralsHelper,
    (0, HashTableExpToIndex.emptyHashTableSized(BaseHashTable.bigBucketSize), {}), {});
  // Broke things :(
  // ((i, ht, literals)) := BackendDAEUtil.traverseBackendDAEExpsNoCopyWithUpdate(dae, findLiteralsHelper, (i, ht, literals));
end simulationFindLiterals;

protected function findLiteralsHelper
  input DAE.Exp inExp;
  input tuple<Integer, HashTableExpToIndex.HashTable, list<DAE.Exp>> inTpl;
  output DAE.Exp exp;
  output tuple<Integer, HashTableExpToIndex.HashTable, list<DAE.Exp>> tpl;
algorithm
  exp := inExp;
  tpl := inTpl;
  (exp, tpl) := Expression.traverseExp(exp, replaceLiteralExp, tpl);
  (exp, tpl) := Expression.traverseExpTopDown(exp, replaceLiteralArrayExp, tpl);
end findLiteralsHelper;

protected function replaceLiteralArrayExp
  "The tuples contain:
  * The expression to be replaced (or not)
  * Index of next literal
  * HashTable Exp->Index (Number of the literal)
  * The list of literals

  Handles only array expressions (needs to be performed in a top-down fashion)
  "
  input DAE.Exp inExp;
  input tuple<Integer, HashTableExpToIndex.HashTable, list<DAE.Exp>> inTpl;
  output DAE.Exp outExp;
  output Boolean cont;
  output tuple<Integer, HashTableExpToIndex.HashTable, list<DAE.Exp>> outTpl;
algorithm
  (outExp,cont,outTpl) := matchcontinue (inExp,inTpl)
    local
      DAE.Exp exp,exp2;
      tuple<Integer, HashTableExpToIndex.HashTable, list<DAE.Exp>> tpl;
    case (DAE.ARRAY(), _)
      equation
        isLiteralArrayExp(inExp);
        (exp2, tpl) = replaceLiteralExp2(inExp, inTpl);
      then (exp2, false, tpl);
    case (exp as DAE.ARRAY(), tpl)
      equation
        failure(isLiteralArrayExp(exp));
      then (exp, false, tpl);
    case (exp as DAE.MATRIX(), _)
      equation
        isLiteralArrayExp(exp);
        (exp2, tpl) = replaceLiteralExp2(inExp, inTpl);
      then (exp2, false, tpl);
    case (exp as DAE.MATRIX(), tpl)
      equation
        failure(isLiteralArrayExp(exp));
      then (exp, false, tpl);
    else (inExp, true, inTpl);
  end matchcontinue;
end replaceLiteralArrayExp;

protected function replaceLiteralExp
  "The tuples contain:
  * The expression to be replaced (or not)
  * Index of next literal
  * HashTable Exp->Index (Number of the literal)
  * The list of literals
  "
  input DAE.Exp inExp;
  input tuple<Integer, HashTableExpToIndex.HashTable, list<DAE.Exp>> inTpl;
  output DAE.Exp outExp;
  output tuple<Integer, HashTableExpToIndex.HashTable, list<DAE.Exp>> outTpl;
algorithm
  (outExp,outTpl) := matchcontinue (inExp,inTpl)
    local
      DAE.Exp exp;
      String msg;
      tuple<Integer, HashTableExpToIndex.HashTable, list<DAE.Exp>> t;
      list<DAE.Exp> es;
    case (exp, t)
      equation
        failure(isLiteralExp(exp));
      then (exp, t);
    case (exp, t)
      equation
        isTrivialLiteralExp(exp);
      then (exp, t);
    case (DAE.LIST(valList=es), t)
      equation
        true = listLength(es) > 25;
        (exp,t) = replaceLiteralExp2(inExp, t);
      then (exp, t); // Too large list; causes performance issues to find all sublists...
    case (exp, t)
      equation
        exp = listToCons(exp);
        (exp, t) = Expression.traverseExp(exp, replaceLiteralExp, t);
      then (exp, t); // All sublists should also be added as literals...
    case (exp, _)
      equation
        failure(_ = listToCons(exp));
        (exp,t) = replaceLiteralExp2(exp, inTpl);
      then (exp, t);
    case (exp, _)
      equation
        msg = "function replaceLiteralExp failed. Falling back to not replacing "+ExpressionDump.printExpStr(exp)+".";
        Error.addInternalError(msg, sourceInfo());
      then (inExp,inTpl);
  end matchcontinue;
end replaceLiteralExp;

protected function replaceLiteralExp2
  "The tuples contain:
  * The expression to be replaced (or not)
  * Index of next literal
  * HashTable Exp->Index (Number of the literal)
  * The list of literals
  "
  input DAE.Exp inExp;
  input tuple<Integer, HashTableExpToIndex.HashTable, list<DAE.Exp>> inTpl;
  output DAE.Exp outExp;
  output tuple<Integer, HashTableExpToIndex.HashTable, list<DAE.Exp>> outTpl;
algorithm
  (outExp,outTpl) := matchcontinue (inExp,inTpl)
    local
      DAE.Exp exp, nexp;
      Integer i, ix;
      list<DAE.Exp> l;
      DAE.Type et;
      HashTableExpToIndex.HashTable ht;
    case (exp, (i, ht, l))
      equation
        ix = BaseHashTable.get(exp, ht);
        nexp = DAE.SHARED_LITERAL(ix, exp);
      then (nexp, (i, ht, l));
    case (exp, (i, ht, l))
      equation
        ht = BaseHashTable.add((exp, i), ht);
        nexp = DAE.SHARED_LITERAL(i, exp);
      then (nexp, (i+1, ht, exp::l));
  end matchcontinue;
end replaceLiteralExp2;

protected function listToCons
"Converts a DAE.LIST to a chain of DAE.CONS"
  input DAE.Exp e;
  output DAE.Exp o;
algorithm
  o := match e
    local
      list<DAE.Exp> es;
    case DAE.LIST(es as _::_) then listToCons2(es);
  end match;
end listToCons;

protected function listToCons2
"Converts a DAE.LIST to a chain of DAE.CONS"
  input list<DAE.Exp> ies;
  output DAE.Exp o;
algorithm
  o := match ies
    local
      DAE.Exp car, cdr;
      list<DAE.Exp> es;
    case ({}) then DAE.LIST({});
    case (car::es)
      equation
        cdr = listToCons2(es);
      then DAE.CONS(car, cdr);
  end match;
end listToCons2;

protected function isTrivialLiteralExp
"Succeeds if the expression should not be translated to a constant literal because it is too simple"
  input DAE.Exp exp;
algorithm
  _ := match exp
    case DAE.BOX(DAE.SCONST(_)) then fail();
    case DAE.BOX(DAE.RCONST(_)) then fail();
    case DAE.BOX(_) then ();
    case DAE.ICONST(_) then ();
    case DAE.BCONST(_) then ();
    case DAE.RCONST(_) then ();
    case DAE.ENUM_LITERAL() then ();
    case DAE.LIST(valList={}) then ();
    case DAE.META_OPTION(NONE()) then ();
    case DAE.SHARED_LITERAL() then ();
    else fail();
  end match;
end isTrivialLiteralExp;

protected function isLiteralArrayExp
  input DAE.Exp iexp;
algorithm
  _ := match iexp
    local
      DAE.Exp e1, e2, exp;
      list<DAE.Exp> expl;
      list<list<DAE.Exp>> expll;

    case DAE.SCONST(_) then ();
    case DAE.ICONST(_) then ();
    case DAE.RCONST(_) then ();
    case DAE.BCONST(_) then ();
    case DAE.ARRAY(array=expl) equation List.map_0(expl, isLiteralArrayExp); then ();
    case DAE.MATRIX(matrix=expll) equation List.map_0(List.flatten(expll), isLiteralArrayExp); then ();
    case DAE.ENUM_LITERAL() then ();
    case DAE.META_OPTION(NONE()) then ();
    case DAE.META_OPTION(SOME(exp)) equation isLiteralArrayExp(exp); then ();
    case DAE.BOX(exp) equation isLiteralArrayExp(exp); then ();
    case DAE.CONS(car = e1, cdr = e2) equation isLiteralArrayExp(e1); isLiteralArrayExp(e2); then ();
    case DAE.LIST(valList = expl) equation List.map_0(expl, isLiteralArrayExp); then ();
    case DAE.META_TUPLE(expl) equation List.map_0(expl, isLiteralArrayExp); then ();
    case DAE.METARECORDCALL(args=expl) equation List.map_0(expl, isLiteralArrayExp); then ();
    case DAE.SHARED_LITERAL() then ();
    else fail();
  end match;
end isLiteralArrayExp;

protected function isLiteralExp
"Returns if the expression may be replaced by a constant literal"
  input DAE.Exp iexp;
algorithm
  _ := match iexp
    local
      DAE.Exp e1, e2, exp;
      list<DAE.Exp> expl;
    case DAE.SCONST(_) then ();
    case DAE.ICONST(_) then ();
    case DAE.RCONST(_) then ();
    case DAE.BCONST(_) then ();
    case DAE.ENUM_LITERAL() then ();
    case DAE.META_OPTION(NONE()) then ();
    case DAE.META_OPTION(SOME(exp)) equation isLiteralExp(exp); then ();
    case DAE.BOX(exp) equation isLiteralExp(exp); then ();
    case DAE.CONS(car = e1, cdr = e2) equation isLiteralExp(e1); isLiteralExp(e2); then ();
    case DAE.LIST(valList = expl) equation List.map_0(expl, isLiteralExp); then ();
    case DAE.META_TUPLE(expl) equation List.map_0(expl, isLiteralExp); then ();
    case DAE.METARECORDCALL(args=expl) equation List.map_0(expl, isLiteralExp); then ();
    case DAE.SHARED_LITERAL() then ();
    else fail();
  end match;
end isLiteralExp;

// =============================================================================
// section to create SimCode from BackendDAE
//
// =============================================================================

public function createSimCode "entry point to create SimCode from BackendDAE."
  input BackendDAE.BackendDAE inBackendDAE;
  input Absyn.Path inClassName;
  input String filenamePrefix;
  input String inString11;
  input list<SimCode.Function> functions;
  input list<String> externalFunctionIncludes;
  input list<String> includeDirs;
  input list<String> libs;
  input list<String> libPaths;
  input Option<SimCode.SimulationSettings> simSettingsOpt;
  input list<SimCode.RecordDeclaration> recordDecls;
  input tuple<Integer, HashTableExpToIndex.HashTable, list<DAE.Exp>> literals;
  input Absyn.FunctionArgs args;
  output SimCode.SimCode simCode;
  output tuple<Integer,list<tuple<Integer,Integer>>> oMapping; //The highest simEqIndex in the mapping and the mapping simEq-Index -> scc-Index itself
algorithm
  (simCode,oMapping) :=
  matchcontinue (inBackendDAE, inClassName, filenamePrefix, inString11, functions, externalFunctionIncludes, includeDirs, libs,libPaths, simSettingsOpt, recordDecls, literals, args)
    local
      String cname, fileDir;
      Integer maxDelayedExpIndex, uniqueEqIndex, numberofEqns, numberOfInitialEquations, numberOfInitialAlgorithms, numStateSets, numberOfJacobians;
      Integer numberofLinearSys, numberofNonLinearSys, numberofMixedSys;
      BackendDAE.BackendDAE dlow;
      Option<BackendDAE.BackendDAE> initDAE;
      DAE.FunctionTree functionTree;
      BackendDAE.SymbolicJacobians symJacs;
      Absyn.Path class_;
      // new variables
      SimCode.ModelInfo modelInfo;
      list<SimCode.SimEqSystem> allEquations;
      list<list<SimCode.SimEqSystem>> odeEquations;         // --> functionODE
      list<list<SimCode.SimEqSystem>> algebraicEquations;   // --> functionAlgebraics
      list<SimCode.SimEqSystem> residuals;                  // --> initial_residual
      Boolean useSymbolicInitialization;                    // true if a system to solve the initial problem symbolically is generated, otherwise false
      Boolean useHomotopy;                                  // true if homotopy(...) is used during initialization
      list<SimCode.SimEqSystem> initialEquations;           // --> initial_equations
      list<SimCode.SimEqSystem> removedInitialEquations;    // -->
      list<SimCode.SimEqSystem> startValueEquations;        // --> updateBoundStartValues
      list<SimCode.SimEqSystem> nominalValueEquations;      // --> updateBoundNominalValues
      list<SimCode.SimEqSystem> minValueEquations;          // --> updateBoundMinValues
      list<SimCode.SimEqSystem> maxValueEquations;          // --> updateBoundMaxValues
      list<SimCode.SimEqSystem> parameterEquations;         // --> updateBoundParameters
      list<SimCode.SimEqSystem> removedEquations;
      list<SimCode.SimEqSystem> algorithmAndEquationAsserts;
      list<SimCode.SimEqSystem> equationsForZeroCrossings;
      list<SimCode.SimEqSystem> jacobianEquations;
      // list<DAE.Statement> algorithmAndEquationAsserts;
      list<DAE.Constraint> constraints;
      list<DAE.ClassAttributes> classAttributes;
      list<BackendDAE.ZeroCrossing> zeroCrossings, sampleZC, relations;
      list<SimCode.SimWhenClause> whenClauses;
      list<DAE.ComponentRef> discreteModelVars;
      SimCode.ExtObjInfo extObjInfo;
      SimCode.MakefileParams makefileParams;
      list<tuple<Integer, tuple<DAE.Exp, DAE.Exp, DAE.Exp>>> delayedExps;

      list<SimCode.JacobianMatrix> LinearMatrices, SymbolicJacs, SymbolicJacsTemp, SymbolicJacsStateSelect, SymbolicJacsNLS;
      SimCode.HashTableCrefToSimVar crefToSimVarHT;
      Boolean ifcpp;
      BackendDAE.EqSystems systs;
      BackendDAE.Shared shared;
      BackendDAE.EquationArray removedEqs;
      list<BackendDAE.Equation> removedInitialEquationLst;

      list<DAE.Exp> lits;
      list<SimCodeVar.SimVar> tempvars, jacobianSimvars;

      list<SimCode.StateSet> stateSets;
      array<Integer> systemIndexMap;
      list<BackendDAE.TimeEvent> timeEvents;
      list<tuple<Integer,Integer>> equationSccMapping, eqBackendSimCodeMapping;
      Integer highestSimEqIndex;
      SimCode.BackendMapping backendMapping;

    case (dlow, class_, _, fileDir, _,_, _, _, _, _, _, _, _) equation
      System.tmpTickReset(0);
      uniqueEqIndex = 1;
      ifcpp = stringEqual(Config.simCodeTarget(), "Cpp");

      backendMapping = setUpBackendMapping(inBackendDAE);

      // fcall(Flags.FAILTRACE, print, "is that Cpp? : " + Dump.printBoolStr(ifcpp) + "\n");

      // generate initDAE before replacing pre(alias)!
      (initDAE, useHomotopy, removedInitialEquationLst) = Initialization.solveInitialSystem(dlow);

      if Flags.isSet(Flags.ITERATION_VARS) then
        BackendDAEOptimize.listAllIterationVariables(dlow);
      end if;

      // replace pre(alias) in time-equations
      dlow = BackendDAEOptimize.simplifyTimeIndepFuncCalls(dlow);

      // check if the Sytems has states
      dlow = BackendDAEUtil.addDummyStateIfNeeded(dlow);

      // initialization stuff
      (residuals, initialEquations, removedInitialEquations, numberOfInitialEquations, numberOfInitialAlgorithms, uniqueEqIndex, tempvars, useSymbolicInitialization) = createInitialResiduals(dlow, initDAE, removedInitialEquationLst, uniqueEqIndex, {});

      // addInitialStmtsToAlgorithms
      dlow = BackendDAEOptimize.addInitialStmtsToAlgorithms(dlow);

      BackendDAE.DAE(systs, shared as BackendDAE.SHARED(removedEqs=removedEqs,
                                                        constraints=constraints,
                                                        classAttrs=classAttributes,
                                                        symjacs=symJacs,
                                                        eventInfo=BackendDAE.EVENT_INFO(timeEvents=timeEvents))) = dlow;


      // created event suff e.g. zeroCrossings, samples, ...
      whenClauses = createSimWhenClauses(dlow);
      zeroCrossings = if ifcpp then FindZeroCrossings.getRelations(dlow) else FindZeroCrossings.getZeroCrossings(dlow);
      relations = FindZeroCrossings.getRelations(dlow);
      sampleZC = FindZeroCrossings.getSamples(dlow);
      zeroCrossings = if ifcpp then listAppend(zeroCrossings, sampleZC) else zeroCrossings;

      // equation generation for euler, dassl2, rungekutta
      (uniqueEqIndex, odeEquations, algebraicEquations, allEquations, equationsForZeroCrossings, tempvars, equationSccMapping, eqBackendSimCodeMapping,backendMapping) = createEquationsForSystems(systs, shared, uniqueEqIndex, {}, {}, {}, {}, zeroCrossings, tempvars, 1, {}, {},backendMapping);
      highestSimEqIndex = uniqueEqIndex;

      ((uniqueEqIndex, removedEquations)) = BackendEquation.traverseEquationArray(removedEqs, traversedlowEqToSimEqSystem, (uniqueEqIndex, {}));

      // Assertions and crap
      // create parameter equations
      ((uniqueEqIndex, startValueEquations)) = BackendDAEUtil.foldEqSystem(dlow, createStartValueEquations, (uniqueEqIndex, {}));
      ((uniqueEqIndex, nominalValueEquations)) = BackendDAEUtil.foldEqSystem(dlow, createNominalValueEquations, (uniqueEqIndex, {}));
      ((uniqueEqIndex, minValueEquations)) = BackendDAEUtil.foldEqSystem(dlow, createMinValueEquations, (uniqueEqIndex, {}));
      ((uniqueEqIndex, maxValueEquations)) = BackendDAEUtil.foldEqSystem(dlow, createMaxValueEquations, (uniqueEqIndex, {}));
      ((uniqueEqIndex, parameterEquations)) = BackendDAEUtil.foldEqSystem(dlow, createVarNominalAssertFromVars, (uniqueEqIndex, {}));
      (uniqueEqIndex, parameterEquations) = createParameterEquations(shared, uniqueEqIndex, parameterEquations, useSymbolicInitialization);

      ((uniqueEqIndex, algorithmAndEquationAsserts)) = BackendDAEUtil.foldEqSystem(dlow, createAlgorithmAndEquationAsserts, (uniqueEqIndex, {}));
      discreteModelVars = BackendDAEUtil.foldEqSystem(dlow, extractDiscreteModelVars, {});
      makefileParams = createMakefileParams(includeDirs, libs, libPaths,false);
      (delayedExps, maxDelayedExpIndex) = extractDelayedExpressions(dlow);

      // append removed equation to all equations, since these are actually
      // just the algorithms without outputs

      algebraicEquations = listAppend(algebraicEquations, removedEquations::{});
      allEquations = listAppend(allEquations, removedEquations);

      // state set stuff
      (dlow, stateSets, uniqueEqIndex, tempvars, numStateSets) = createStateSets(dlow, {}, uniqueEqIndex, tempvars);

      // create model info
      modelInfo = createModelInfo(class_, dlow, functions, {}, numberOfInitialEquations, numberOfInitialAlgorithms, numStateSets, fileDir);
      modelInfo = addTempVars(tempvars, modelInfo);

      // external objects
      extObjInfo = createExtObjInfo(shared);

      // update index of zero-Crossings after equations are created
      zeroCrossings = updateZeroCrossEqnIndex(zeroCrossings, eqBackendSimCodeMapping, BackendDAEUtil.daeSize(dlow));

      // update indexNonLinear in SES_NONLINEAR and count
      SymbolicJacsNLS = {};
      (initialEquations, numberofLinearSys, numberofNonLinearSys, numberofMixedSys, numberOfJacobians, SymbolicJacsTemp) = countandIndexAlgebraicLoops(initialEquations, 0, 0, 0, 0, {});
      SymbolicJacsNLS = listAppend(SymbolicJacsTemp, SymbolicJacsNLS);
      (parameterEquations, numberofLinearSys, numberofNonLinearSys, numberofMixedSys, numberOfJacobians, SymbolicJacsTemp) = countandIndexAlgebraicLoops(parameterEquations, numberofLinearSys, numberofNonLinearSys, numberofMixedSys, numberOfJacobians, {});
      SymbolicJacsNLS = listAppend(SymbolicJacsTemp, SymbolicJacsNLS);
      (allEquations, numberofLinearSys, numberofNonLinearSys, numberofMixedSys, numberOfJacobians, SymbolicJacsTemp) = countandIndexAlgebraicLoops(allEquations, numberofLinearSys, numberofNonLinearSys, numberofMixedSys, numberOfJacobians, {});
      SymbolicJacsNLS = listAppend(SymbolicJacsTemp, SymbolicJacsNLS);

      // collect symbolic jacobians from state selection
      (stateSets, SymbolicJacsStateSelect, numberOfJacobians) = indexStateSets(stateSets, {}, numberOfJacobians, {});

      // generate jacobian or linear model matrices
      (LinearMatrices,uniqueEqIndex) = createJacobianLinearCode(symJacs, modelInfo, uniqueEqIndex);

      // collect jacobian equation only for equantion info file
      jacobianEquations = collectAllJacobianEquations(LinearMatrices, {});

      // collect symbolic jacobians in linear loops of the overall jacobians
      (_, numberofLinearSys, numberofNonLinearSys, numberofMixedSys, numberOfJacobians, SymbolicJacs) = countandIndexAlgebraicLoops({}, numberofLinearSys, numberofNonLinearSys, numberofMixedSys, numberOfJacobians, LinearMatrices);

      jacobianEquations = collectAllJacobianEquations(SymbolicJacsStateSelect, jacobianEquations);
      SymbolicJacsNLS = listAppend(SymbolicJacsNLS, SymbolicJacsStateSelect);
      SymbolicJacs = listAppend(SymbolicJacsNLS, SymbolicJacs);
      jacobianSimvars = collectAllJacobianVars(SymbolicJacs, {});
      modelInfo = addJacobianVars(jacobianSimvars, modelInfo);

      // map index also odeEquations and algebraicEquations
      systemIndexMap = List.fold(allEquations, getSystemIndexMap, arrayCreate(uniqueEqIndex, -1));
      odeEquations = List.mapList1_1(odeEquations, setSystemIndexMap, systemIndexMap);
      algebraicEquations = List.mapList1_1(algebraicEquations, setSystemIndexMap, systemIndexMap);
      numberofEqns = uniqueEqIndex; /* This is a *much* better estimate than the guessed number of equations */

      // create model info
      modelInfo = addNumEqnsandNumofSystems(modelInfo, numberofEqns, numberofLinearSys, numberofNonLinearSys, numberofMixedSys, numberOfJacobians);

      // replace div operator with div operator with check of Division by zero
      allEquations = List.map(allEquations, addDivExpErrorMsgtoSimEqSystem);
      odeEquations = List.mapList(odeEquations, addDivExpErrorMsgtoSimEqSystem);
      algebraicEquations = List.mapList(algebraicEquations, addDivExpErrorMsgtoSimEqSystem);
      residuals = List.map(residuals, addDivExpErrorMsgtoSimEqSystem);
      startValueEquations = List.map(startValueEquations, addDivExpErrorMsgtoSimEqSystem);
      nominalValueEquations = List.map(nominalValueEquations, addDivExpErrorMsgtoSimEqSystem);
      minValueEquations = List.map(minValueEquations, addDivExpErrorMsgtoSimEqSystem);
      maxValueEquations = List.map(maxValueEquations, addDivExpErrorMsgtoSimEqSystem);
      parameterEquations = List.map(parameterEquations, addDivExpErrorMsgtoSimEqSystem);
      removedEquations = List.map(removedEquations, addDivExpErrorMsgtoSimEqSystem);
      initialEquations = List.map(initialEquations, addDivExpErrorMsgtoSimEqSystem);
      removedInitialEquations = List.map(removedInitialEquations, addDivExpErrorMsgtoSimEqSystem);

      odeEquations = makeEqualLengthLists(odeEquations, Config.noProc());
      algebraicEquations = makeEqualLengthLists(algebraicEquations, Config.noProc());

      // Filter out empty systems to improve code generation
      odeEquations = List.filterOnTrue(odeEquations, List.isNotEmpty);
      algebraicEquations = List.filterOnTrue(algebraicEquations, List.isNotEmpty);

      if Flags.isSet(Flags.EXEC_HASH) then
        print("*** SimCode -> generate cref2simVar hastable: " + realString(clock()) + "\n");
      end if;
      crefToSimVarHT = createCrefToSimVarHT(modelInfo);
      if Flags.isSet(Flags.EXEC_HASH) then
        print("*** SimCode -> generate cref2simVar hastable done!: " + realString(clock()) + "\n");
      end if;

      backendMapping = setBackendVarMapping(inBackendDAE,crefToSimVarHT,modelInfo,backendMapping);
      //dumpBackendMapping(backendMapping);

      simCode = SimCode.SIMCODE(modelInfo,
                                {}, // Set by the traversal below...
                                recordDecls,
                                externalFunctionIncludes,
                                allEquations,
                                odeEquations,
                                algebraicEquations,
                                residuals,
                                useSymbolicInitialization,
                                useHomotopy,
                                initialEquations,
                                removedInitialEquations,
                                startValueEquations,
                                nominalValueEquations,
                                minValueEquations,
                                maxValueEquations,
                                parameterEquations,
                                removedEquations,
                                algorithmAndEquationAsserts,
                                equationsForZeroCrossings,
                                jacobianEquations,
                                stateSets,
                                constraints,
                                classAttributes,
                                zeroCrossings,
                                relations,
                                timeEvents,
                                whenClauses,
                                discreteModelVars,
                                extObjInfo,
                                makefileParams,
                                SimCode.DELAYED_EXPRESSIONS(delayedExps, maxDelayedExpIndex),
                                SymbolicJacs,
                                simSettingsOpt,
                                filenamePrefix,
                                NONE(),
                                NONE(),
                                {},
                                crefToSimVarHT,
                                SOME(backendMapping));
      (simCode, (_, _, lits)) = traverseExpsSimCode(simCode, findLiteralsHelper, literals);
      simCode = setSimCodeLiterals(simCode, listReverse(lits));

      // print("*** SimCode -> collect all files started: " + realString(clock()) + "\n");
      // adrpo: collect all the files from SourceInfo and DAE.ElementSource
      // simCode = collectAllFiles(simCode);
      // print("*** SimCode -> collect all files done!: " + realString(clock()) + "\n");
    then (simCode, (highestSimEqIndex, equationSccMapping));

    else equation
      Error.addInternalError("function createSimCode failed [Transformation from optimised DAE to simulation code structure failed]", sourceInfo());
    then fail();
  end matchcontinue;
end createSimCode;

protected function addTempVars
  input list<SimCodeVar.SimVar> tempVars;
  input SimCode.ModelInfo modelInfo;
  output SimCode.ModelInfo omodelInfo;
algorithm
  omodelInfo := match(tempVars, modelInfo)
    local
      Absyn.Path name;
      String description,directory;
      SimCode.VarInfo varInfo;
      SimCodeVar.SimVars vars;
      list<SimCodeVar.SimVar> stateVars, derivativeVars, algVars, discreteAlgVars, intAlgVars, boolAlgVars, inputVars, outputVars, aliasVars, intAliasVars, boolAliasVars, paramVars, intParamVars, boolParamVars;
      list<SimCodeVar.SimVar> stringAlgVars, stringParamVars, stringAliasVars, extObjVars, constVars, intConstVars, boolConstVars, stringConstVars, jacobianVars, realOptimizeConstraintsVars, realOptimizeFinalConstraintsVars;
      list<SimCode.Function> functions;
      list<String> labels;
      Integer numZeroCrossings, numTimeEvents, numRelations, numMathEvents;
      Integer numStateVars, numAlgVars, numDiscreteReal, numIntAlgVars, numBoolAlgVars, numAlgAliasVars, numIntAliasVars, numBoolAliasVars;
      Integer numParams, numIntParams, numBoolParams, numOutVars, numInVars;
      Integer numInitialEquations, numInitialAlgorithms, numInitialResiduals, numExternalObjects, numStringAlgVars;
      Integer numStringParamVars, numStringAliasVars, numStateSets, numOptimizeConstraints, numOptimizeFinalConstraints;
      Integer numEqns;
      Integer numLinearSys, numNonLinearSys, numMixedLinearSys, numJacobians;
    case({}, _) then modelInfo;
    case(_, SimCode.MODELINFO(name, description, directory, varInfo, vars, functions, labels))
      equation
        SimCode.VARINFO(numZeroCrossings, numTimeEvents, numRelations, numMathEvents, numStateVars, numAlgVars, numDiscreteReal, numIntAlgVars, numBoolAlgVars, numAlgAliasVars, numIntAliasVars, numBoolAliasVars, numParams,
           numIntParams, numBoolParams, numOutVars, numInVars, numInitialEquations, numInitialAlgorithms, numInitialResiduals, numExternalObjects, numStringAlgVars,
           numStringParamVars, numStringAliasVars, numEqns, numLinearSys, numNonLinearSys, numMixedLinearSys, numStateSets, numJacobians, numOptimizeConstraints, numOptimizeFinalConstraints) = varInfo;
        SimCodeVar.SIMVARS(stateVars, derivativeVars, algVars, discreteAlgVars, intAlgVars, boolAlgVars, inputVars, outputVars, aliasVars, intAliasVars, boolAliasVars, paramVars, intParamVars, boolParamVars,
               stringAlgVars, stringParamVars, stringAliasVars, extObjVars, constVars, intConstVars, boolConstVars, stringConstVars, jacobianVars,realOptimizeConstraintsVars, realOptimizeFinalConstraintsVars) = vars;

       (numAlgVars, algVars, numIntAlgVars, intAlgVars, numBoolAlgVars, boolAlgVars, numStringAlgVars, stringAlgVars)=
          addTempVars1(tempVars, numAlgVars, listReverse(algVars), numIntAlgVars, listReverse(intAlgVars), numBoolAlgVars, listReverse(boolAlgVars), numStringAlgVars, listReverse(stringAlgVars));

        algVars = listReverse(algVars);
        intAlgVars = listReverse(intAlgVars);
        boolAlgVars = listReverse(boolAlgVars);
        stringAlgVars = listReverse(stringAlgVars);

        varInfo = SimCode.VARINFO(numZeroCrossings, numTimeEvents, numRelations, numMathEvents, numStateVars, numAlgVars, numDiscreteReal, numIntAlgVars, numBoolAlgVars, numAlgAliasVars, numIntAliasVars, numBoolAliasVars, numParams,
           numIntParams, numBoolParams, numOutVars, numInVars, numInitialEquations, numInitialAlgorithms, numInitialResiduals, numExternalObjects, numStringAlgVars,
           numStringParamVars, numStringAliasVars, numEqns, numLinearSys, numNonLinearSys, numMixedLinearSys, numStateSets, numJacobians, numOptimizeConstraints, numOptimizeFinalConstraints);
        vars = SimCodeVar.SIMVARS(stateVars, derivativeVars, algVars, discreteAlgVars, intAlgVars, boolAlgVars, inputVars, outputVars, aliasVars, intAliasVars, boolAliasVars, paramVars, intParamVars, boolParamVars,
               stringAlgVars, stringParamVars, stringAliasVars, extObjVars, constVars, intConstVars, boolConstVars, stringConstVars, jacobianVars, realOptimizeConstraintsVars, realOptimizeFinalConstraintsVars);
      then
       SimCode.MODELINFO(name, description, directory, varInfo, vars, functions, labels);
  end match;
end addTempVars;

protected function addTempVars1
  input list<SimCodeVar.SimVar> tempVars;
  input Integer numAlgVars;
  input list<SimCodeVar.SimVar> algVars;
  input Integer numIntAlgVars;
  input list<SimCodeVar.SimVar> intAlgVars;
  input Integer numBoolAlgVars;
  input list<SimCodeVar.SimVar> boolAlgVars;
  input Integer numStringAlgVars;
  input list<SimCodeVar.SimVar> stringAlgVars;
  output Integer onumAlgVars;
  output list<SimCodeVar.SimVar> oalgVars;
  output Integer onumIntAlgVars;
  output list<SimCodeVar.SimVar> ointAlgVars;
  output Integer onumBoolAlgVars;
  output list<SimCodeVar.SimVar> oboolAlgVars;
  output Integer onumStringAlgVars;
  output list<SimCodeVar.SimVar> ostringAlgVars;
algorithm
  (onumAlgVars, oalgVars, onumIntAlgVars, ointAlgVars, onumBoolAlgVars, oboolAlgVars, onumStringAlgVars, ostringAlgVars) :=
   match(tempVars, numAlgVars, algVars, numIntAlgVars, intAlgVars, numBoolAlgVars, boolAlgVars, numStringAlgVars, stringAlgVars)
     local
      SimCodeVar.SimVar var;
      list<SimCodeVar.SimVar> rest;
      DAE.ComponentRef name;
      BackendDAE.VarKind varKind;
      String comment, unit;
      String displayUnit;
      Integer index;
      Option<DAE.Exp> minValue, maxValue, initialValue, nominalValue;
      Boolean isFixed;
      DAE.Type type_;
      Boolean isDiscrete, isValueChangeable;
      Option<DAE.ComponentRef> arrayCref;
      SimCodeVar.AliasVariable aliasvar;
      DAE.ElementSource source;
      SimCodeVar.Causality causality;
      Option<Integer> variable_index;
      list<String> numArrayElement;
      Boolean isProtected;
     case({}, _, _, _, _, _, _, _, _) then (numAlgVars, algVars, numIntAlgVars, intAlgVars, numBoolAlgVars, boolAlgVars, numStringAlgVars, stringAlgVars);
     case(SimCodeVar.SIMVAR(name, varKind, comment, unit, displayUnit, _, minValue, maxValue, initialValue, nominalValue, isFixed, type_ as DAE.T_INTEGER(),
          isDiscrete, arrayCref, aliasvar, source, causality, variable_index, numArrayElement, isValueChangeable, isProtected)::rest, _, _, _, _, _, _, _, _)
       equation
         var = SimCodeVar.SIMVAR(name, varKind, comment, unit, displayUnit, numIntAlgVars, minValue, maxValue, initialValue, nominalValue, isFixed, type_,
          isDiscrete, arrayCref, aliasvar, source, causality, variable_index, numArrayElement, isValueChangeable, isProtected);
         (onumAlgVars, oalgVars, onumIntAlgVars, ointAlgVars, onumBoolAlgVars, oboolAlgVars, onumStringAlgVars, ostringAlgVars) =
         addTempVars1(rest, numAlgVars, algVars, numIntAlgVars+1, var::intAlgVars, numBoolAlgVars, boolAlgVars, numStringAlgVars, stringAlgVars);
       then
         (onumAlgVars, oalgVars, onumIntAlgVars, ointAlgVars, onumBoolAlgVars, oboolAlgVars, onumStringAlgVars, ostringAlgVars);
     case(SimCodeVar.SIMVAR(name, varKind, comment, unit, displayUnit, _, minValue, maxValue, initialValue, nominalValue, isFixed, type_ as DAE.T_ENUMERATION(),
          isDiscrete, arrayCref, aliasvar, source, causality, variable_index, numArrayElement, isValueChangeable, isProtected)::rest, _, _, _, _, _, _, _, _)
       equation
         var = SimCodeVar.SIMVAR(name, varKind, comment, unit, displayUnit, numIntAlgVars, minValue, maxValue, initialValue, nominalValue, isFixed, type_,
          isDiscrete, arrayCref, aliasvar, source, causality, variable_index, numArrayElement, isValueChangeable, isProtected);
         (onumAlgVars, oalgVars, onumIntAlgVars, ointAlgVars, onumBoolAlgVars, oboolAlgVars, onumStringAlgVars, ostringAlgVars) =
         addTempVars1(rest, numAlgVars, algVars, numIntAlgVars+1, var::intAlgVars, numBoolAlgVars, boolAlgVars, numStringAlgVars, stringAlgVars);
       then
         (onumAlgVars, oalgVars, onumIntAlgVars, ointAlgVars, onumBoolAlgVars, oboolAlgVars, onumStringAlgVars, ostringAlgVars);
     case(SimCodeVar.SIMVAR(name, varKind, comment, unit, displayUnit, _, minValue, maxValue, initialValue, nominalValue, isFixed, type_ as DAE.T_BOOL(),
          isDiscrete, arrayCref, aliasvar, source, causality, variable_index, numArrayElement, isValueChangeable, isProtected)::rest, _, _, _, _, _, _, _, _)
       equation
         var = SimCodeVar.SIMVAR(name, varKind, comment, unit, displayUnit, numBoolAlgVars, minValue, maxValue, initialValue, nominalValue, isFixed, type_,
          isDiscrete, arrayCref, aliasvar, source, causality, variable_index, numArrayElement, isValueChangeable, isProtected);
         (onumAlgVars, oalgVars, onumIntAlgVars, ointAlgVars, onumBoolAlgVars, oboolAlgVars, onumStringAlgVars, ostringAlgVars) =
         addTempVars1(rest, numAlgVars, algVars, numIntAlgVars, intAlgVars, numBoolAlgVars+1, var::boolAlgVars, numStringAlgVars, stringAlgVars);
       then
         (onumAlgVars, oalgVars, onumIntAlgVars, ointAlgVars, onumBoolAlgVars, oboolAlgVars, onumStringAlgVars, ostringAlgVars);
     case(SimCodeVar.SIMVAR(name, varKind, comment, unit, displayUnit, _, minValue, maxValue, initialValue, nominalValue, isFixed, type_ as DAE.T_STRING(),
          isDiscrete, arrayCref, aliasvar, source, causality, variable_index, numArrayElement, isValueChangeable, isProtected)::rest, _, _, _, _, _, _, _, _)
       equation
         var = SimCodeVar.SIMVAR(name, varKind, comment, unit, displayUnit, numStringAlgVars, minValue, maxValue, initialValue, nominalValue, isFixed, type_,
          isDiscrete, arrayCref, aliasvar, source, causality, variable_index, numArrayElement, isValueChangeable, isProtected);
         (onumAlgVars, oalgVars, onumIntAlgVars, ointAlgVars, onumBoolAlgVars, oboolAlgVars, onumStringAlgVars, ostringAlgVars) =
         addTempVars1(rest, numAlgVars, algVars, numIntAlgVars, intAlgVars, numBoolAlgVars, boolAlgVars, numStringAlgVars+1, var::stringAlgVars);
       then
         (onumAlgVars, oalgVars, onumIntAlgVars, ointAlgVars, onumBoolAlgVars, oboolAlgVars, onumStringAlgVars, ostringAlgVars);
     case(SimCodeVar.SIMVAR(name, varKind, comment, unit, displayUnit, _, minValue, maxValue, initialValue, nominalValue, isFixed, type_,
          isDiscrete, arrayCref, aliasvar, source, causality, variable_index, numArrayElement, isValueChangeable, isProtected)::rest, _, _, _, _, _, _, _, _)
       equation
         var = SimCodeVar.SIMVAR(name, varKind, comment, unit, displayUnit, numAlgVars, minValue, maxValue, initialValue, nominalValue, isFixed, type_,
          isDiscrete, arrayCref, aliasvar, source, causality, variable_index, numArrayElement, isValueChangeable, isProtected);
         (onumAlgVars, oalgVars, onumIntAlgVars, ointAlgVars, onumBoolAlgVars, oboolAlgVars, onumStringAlgVars, ostringAlgVars) =
         addTempVars1(rest, numAlgVars+1, var::algVars, numIntAlgVars, intAlgVars, numBoolAlgVars, boolAlgVars, numStringAlgVars, stringAlgVars);
       then
         (onumAlgVars, oalgVars, onumIntAlgVars, ointAlgVars, onumBoolAlgVars, oboolAlgVars, onumStringAlgVars, ostringAlgVars);
   end match;
end addTempVars1;

protected function addJacobianVars
  input list<SimCodeVar.SimVar> jacobianVars;
  input SimCode.ModelInfo modelInfo;
  output SimCode.ModelInfo omodelInfo;
algorithm
  omodelInfo := match(jacobianVars, modelInfo)
    local
      Absyn.Path name;
      String description,directory;
      SimCode.VarInfo varInfo;
      SimCodeVar.SimVars vars;
      list<SimCodeVar.SimVar> stateVars, derivativeVars, algVars, discreteAlgVars, intAlgVars, boolAlgVars, inputVars, outputVars, aliasVars, intAliasVars, boolAliasVars, paramVars, intParamVars, boolParamVars;
      list<SimCodeVar.SimVar> stringAlgVars, stringParamVars, stringAliasVars, extObjVars, constVars, intConstVars, boolConstVars, stringConstVars, jacobiansVars,realOptimizeConstraintsVars, realOptimizeFinalConstraintsVars;
      list<SimCode.Function> functions;
      list<String> labels;
    case({}, _) then modelInfo;
    case(_, SimCode.MODELINFO(name, description, directory, varInfo, vars, functions, labels))
      equation
        SimCodeVar.SIMVARS(stateVars, derivativeVars, algVars, discreteAlgVars, intAlgVars, boolAlgVars, inputVars, outputVars, aliasVars, intAliasVars, boolAliasVars, paramVars, intParamVars, boolParamVars,
               stringAlgVars, stringParamVars, stringAliasVars, extObjVars, constVars, intConstVars, boolConstVars, stringConstVars, _, realOptimizeConstraintsVars, realOptimizeFinalConstraintsVars) = vars;

        vars = SimCodeVar.SIMVARS(stateVars, derivativeVars, algVars, discreteAlgVars, intAlgVars, boolAlgVars, inputVars, outputVars, aliasVars, intAliasVars, boolAliasVars, paramVars, intParamVars, boolParamVars,
               stringAlgVars, stringParamVars, stringAliasVars, extObjVars, constVars, intConstVars, boolConstVars, stringConstVars, jacobianVars,realOptimizeConstraintsVars, realOptimizeFinalConstraintsVars);
      then
       SimCode.MODELINFO(name, description, directory, varInfo, vars, functions, labels);
  end match;
end addJacobianVars;

protected function addNumEqnsandNumofSystems
  input SimCode.ModelInfo modelInfo;
  input Integer numEqns;
  input Integer numLinearSys;
  input Integer numNonLinearSys;
  input Integer numMixedLinearSys;
  input Integer numOfJacobians;
  output SimCode.ModelInfo omodelInfo;
algorithm
  omodelInfo := match(modelInfo, numEqns, numLinearSys, numNonLinearSys, numMixedLinearSys, numOfJacobians)
    local
    Absyn.Path name;
    String description,directory;
    SimCode.VarInfo varInfo;
    SimCodeVar.SimVars vars;
    list<SimCode.Function> functions;
    list<String> labels;
    Integer numZeroCrossings, numTimeEvents, numRelations, numMathEvents;
    Integer numStateVars, numAlgVars, numDiscreteReal, numIntAlgVars, numBoolAlgVars, numAlgAliasVars, numIntAliasVars, numBoolAliasVars;
    Integer numParams, numIntParams, numBoolParams, numOutVars, numInVars;
    Integer numInitialEquations, numInitialAlgorithms, numInitialResiduals, numExternalObjects, numStringAlgVars;
    Integer numStringParamVars, numStringAliasVars, numStateSets, numJacobians, numOptimizeConstraints, numOptimizeFinalConstraints;


    case(SimCode.MODELINFO(name, description, directory, varInfo, vars, functions, labels), _, _, _, _, _) equation
      SimCode.VARINFO(numZeroCrossings, numTimeEvents, numRelations, numMathEvents, numStateVars, numAlgVars, numDiscreteReal, numIntAlgVars, numBoolAlgVars, numAlgAliasVars, numIntAliasVars, numBoolAliasVars, numParams,
      numIntParams, numBoolParams, numOutVars, numInVars, numInitialEquations, numInitialAlgorithms, numInitialResiduals, numExternalObjects, numStringAlgVars,
      numStringParamVars, numStringAliasVars, _, _, _, _, numStateSets, _, numOptimizeConstraints,numOptimizeFinalConstraints) = varInfo;
      varInfo = SimCode.VARINFO(numZeroCrossings, numTimeEvents, numRelations, numMathEvents, numStateVars, numAlgVars, numDiscreteReal, numIntAlgVars, numBoolAlgVars, numAlgAliasVars, numIntAliasVars, numBoolAliasVars, numParams,
      numIntParams, numBoolParams, numOutVars, numInVars, numInitialEquations, numInitialAlgorithms, numInitialResiduals, numExternalObjects, numStringAlgVars,
      numStringParamVars, numStringAliasVars, numEqns, numLinearSys, numNonLinearSys, numMixedLinearSys, numStateSets, numOfJacobians, numOptimizeConstraints,numOptimizeFinalConstraints);
    then SimCode.MODELINFO(name, description, directory, varInfo, vars, functions, labels);
  end match;
end addNumEqnsandNumofSystems;

protected function getSystemIndexMap
  input SimCode.SimEqSystem inEqn;
  input array<Integer> inSysIndexMap;
  output array<Integer> outSysIndexMap;
algorithm
  outSysIndexMap := match(inEqn, inSysIndexMap)
    local
      Integer index, systemIndex;
      array<Integer> sysIndexMap;
      SimCode.SimEqSystem cont;
      list<SimCode.SimEqSystem> eqs;

    case(SimCode.SES_LINEAR(index=index, indexLinearSystem=systemIndex), _) equation
      sysIndexMap = arrayUpdate(inSysIndexMap, index, systemIndex);
    then sysIndexMap;

    case(SimCode.SES_NONLINEAR(index=index, eqs=eqs, indexNonLinearSystem=systemIndex), _) equation
      sysIndexMap = List.fold(eqs, getSystemIndexMap, inSysIndexMap);
      sysIndexMap = arrayUpdate(sysIndexMap, index, systemIndex);
    then sysIndexMap;

    case(SimCode.SES_MIXED(cont=cont, index=index, indexMixedSystem=systemIndex), _) equation
      getSystemIndexMap(cont, inSysIndexMap);
      sysIndexMap = arrayUpdate(inSysIndexMap, index, systemIndex);
    then sysIndexMap;

    else inSysIndexMap;
  end match;
end getSystemIndexMap;

protected function setSystemIndexMap "
  updates index of strong components systems"
  input SimCode.SimEqSystem inEqn;
  input array<Integer> inSysIndexMap;
  output SimCode.SimEqSystem outEqn;
algorithm
  outEqn := match(inEqn, inSysIndexMap)
    local
      Integer index, sysIndex;
      list<SimCode.SimEqSystem> eqs;
      list<DAE.ComponentRef> crefs;
      SimCode.SimEqSystem cont;
      list<SimCodeVar.SimVar> discVars;
      list<SimCode.SimEqSystem> discEqs;
      Option<SimCode.JacobianMatrix> optSymJac;
      Boolean partOfMixed;
      list<SimCodeVar.SimVar> vars;
      list<DAE.Exp> beqs;
      Boolean linearTearing;
      list<tuple<Integer, Integer, SimCode.SimEqSystem>> simJac;
      list<DAE.ElementSource> sources;
      Boolean homotopySupport;
      Boolean mixedSystem;

    case(SimCode.SES_LINEAR(index, partOfMixed, vars, beqs, simJac, eqs, optSymJac, sources, _), _) equation
      sysIndex = inSysIndexMap[index];
    then SimCode.SES_LINEAR(index, partOfMixed, vars, beqs, simJac, eqs, optSymJac, sources, sysIndex);

    case(SimCode.SES_NONLINEAR(index, eqs, crefs, _, optSymJac, linearTearing, homotopySupport, mixedSystem), _) equation
      eqs = List.map1(eqs, setSystemIndexMap, inSysIndexMap);
      sysIndex = inSysIndexMap[index];
    then SimCode.SES_NONLINEAR(index, eqs, crefs, sysIndex, optSymJac, linearTearing, homotopySupport, mixedSystem);

    case(SimCode.SES_MIXED(index, cont, discVars, discEqs, _), _) equation
      sysIndex = inSysIndexMap[index];
      cont = setSystemIndexMap(cont, inSysIndexMap);
    then SimCode.SES_MIXED(index, cont, discVars, discEqs, sysIndex);

    else
    then inEqn;
  end match;
end setSystemIndexMap;

protected function countandIndexAlgebraicLoops "
  counts algebraic loops and updates index of the systems, further all
  symbolic jacobians are collected and therefore we also need to seek
  for algebraic loops."
  input list<SimCode.SimEqSystem> inEqns;
  input Integer inLinearSysIndex;
  input Integer inNonLinSysIndex;
  input Integer inMixedSysIndex;
  input Integer inJacobianIndex;
  input list<SimCode.JacobianMatrix> inSymJacs;
  output list<SimCode.SimEqSystem> outEqns;
  output Integer outLinearSysIndex;
  output Integer outNonLinSysIndex;
  output Integer outMixedSysIndex;
  output Integer outJacobianIndex;
  output list<SimCode.JacobianMatrix> outSymJacs;
algorithm
  (outEqns, outSymJacs, outLinearSysIndex, outNonLinSysIndex, outMixedSysIndex, outJacobianIndex) := countandIndexAlgebraicLoopsWork(inEqns, inSymJacs, inLinearSysIndex, inNonLinSysIndex, inMixedSysIndex, inJacobianIndex, {}, {});
end countandIndexAlgebraicLoops;

protected function countandIndexAlgebraicLoopsWork "
  counts algebraic loops and updates index of the systems, further all
  symbolic jacobians are collected and therefore we also need to seek
  for algebraic loops."
  input list<SimCode.SimEqSystem> inEqns;
  input list<SimCode.JacobianMatrix> inSymJacs;
  input Integer inLinearSysIndex;
  input Integer inNonLinSysIndex;
  input Integer inMixedSysIndex;
  input Integer inJacobianIndex;
  input list<SimCode.SimEqSystem> inEqnsAcc;
  input list<SimCode.JacobianMatrix> inSymJacsAcc;
  output list<SimCode.SimEqSystem> outEqns;
  output list<SimCode.JacobianMatrix> outSymJacs;
  output Integer outLinearSysIndex;
  output Integer outNonLinSysIndex;
  output Integer outMixedSysIndex;
  output Integer outJacobianIndex;
algorithm
  (outEqns, outSymJacs, outLinearSysIndex, outNonLinSysIndex, outMixedSysIndex, outJacobianIndex) := match(inEqns, inSymJacs, inLinearSysIndex, inNonLinSysIndex, inMixedSysIndex, inJacobianIndex, inEqnsAcc, inSymJacsAcc)
    local
      Integer index, countLinearSys, countNonLinSys, countMixedSys, countJacobians;
      list<SimCode.SimEqSystem> eqs, rest, res, accEqs;
      list<DAE.ComponentRef> crefs;
      SimCode.SimEqSystem eq, cont;
      list<SimCodeVar.SimVar> discVars;
      list<SimCode.SimEqSystem> discEqs;
      list<SimCode.JacobianMatrix> symjacs, restSymJacs, accJac;
      Option<SimCode.JacobianMatrix> optSymJac;
      SimCode.JacobianMatrix symJac;
      Boolean partOfMixed;
      list<SimCodeVar.SimVar> vars;
      list<DAE.Exp> beqs;
      list<tuple<Integer, Integer, SimCode.SimEqSystem>> simJac;
      Boolean linearTearing;
      list<DAE.ElementSource> sources;
      Boolean homotopySupport;
      Boolean mixedSystem;

    case ({}, {}, _, _, _, _, _, _)
      then (listReverse(inEqnsAcc), inSymJacsAcc, inLinearSysIndex, inNonLinSysIndex, inMixedSysIndex, inJacobianIndex);

    case ({}, symJac::restSymJacs, _, _, _, _, _, _)
      equation
        (symJac, countLinearSys, countNonLinSys, countMixedSys, countJacobians, symjacs) = countandIndexAlgebraicLoopsSymJac(symJac, inLinearSysIndex, inNonLinSysIndex, inMixedSysIndex, inJacobianIndex);
        symjacs = listAppend(symjacs,inSymJacsAcc);
        (eqs, symjacs, countLinearSys, countNonLinSys, countMixedSys, countJacobians) = countandIndexAlgebraicLoopsWork({}, restSymJacs, countLinearSys, countNonLinSys, countMixedSys, countJacobians, inEqnsAcc, symJac::symjacs);
      then (eqs, symjacs, countLinearSys, countNonLinSys, countMixedSys, countJacobians);

    case(SimCode.SES_NONLINEAR(index, eqs, crefs, _, NONE(), linearTearing, homotopySupport, mixedSystem)::rest, _, _, _, _, _, _, _)
      equation
        (eqs,_, countLinearSys, countNonLinSys, countMixedSys, countJacobians) = countandIndexAlgebraicLoopsWork(eqs, {}, inLinearSysIndex, inNonLinSysIndex+1, inMixedSysIndex, inJacobianIndex, {}, {});
        (res, symjacs, countLinearSys, countNonLinSys, countMixedSys, countJacobians) = countandIndexAlgebraicLoopsWork(rest, inSymJacs, countLinearSys, countNonLinSys, countMixedSys, countJacobians, SimCode.SES_NONLINEAR(index, eqs, crefs, inNonLinSysIndex, NONE(), linearTearing, homotopySupport, mixedSystem)::inEqnsAcc, inSymJacsAcc);
      then (res, symjacs, countLinearSys, countNonLinSys, countMixedSys, countJacobians);

    case(SimCode.SES_NONLINEAR(index, eqs, crefs, _, SOME(symJac), linearTearing, homotopySupport, mixedSystem)::rest, _, _, _, _, _, _, _)
      equation
        (eqs, symjacs, countLinearSys, countNonLinSys, countMixedSys, countJacobians) = countandIndexAlgebraicLoopsWork(eqs, {}, inLinearSysIndex, inNonLinSysIndex+1, inMixedSysIndex, inJacobianIndex, {}, {});
        (symJac, countLinearSys, countNonLinSys, countMixedSys, countJacobians, symjacs) = countandIndexAlgebraicLoopsSymJac(symJac, countLinearSys, countNonLinSys, countMixedSys, countJacobians);
        (res, symjacs, countLinearSys, countNonLinSys, countMixedSys, countJacobians) = countandIndexAlgebraicLoopsWork(rest, listAppend(symjacs,inSymJacs), countLinearSys, countNonLinSys, countMixedSys, countJacobians, SimCode.SES_NONLINEAR(index, eqs, crefs, inNonLinSysIndex, SOME(symJac), linearTearing, homotopySupport, mixedSystem)::inEqnsAcc, symJac::inSymJacsAcc);
      then (res, symjacs, countLinearSys, countNonLinSys, countMixedSys, countJacobians);

    case (SimCode.SES_LINEAR(index, partOfMixed, vars, beqs, simJac, eqs, NONE(), sources, _)::rest, _, _, _, _, _, _, _)
      equation
        (eqs,_, countLinearSys, countNonLinSys, countMixedSys, countJacobians) = countandIndexAlgebraicLoopsWork(eqs, {}, inLinearSysIndex+1, inNonLinSysIndex, inMixedSysIndex, inJacobianIndex,  {}, {});
        (res, symjacs, countLinearSys, countNonLinSys, countMixedSys, countJacobians) = countandIndexAlgebraicLoopsWork(rest, inSymJacs, countLinearSys, countNonLinSys, countMixedSys, countJacobians,  SimCode.SES_LINEAR(index, partOfMixed, vars, beqs, simJac, eqs, NONE(), sources, inLinearSysIndex)::inEqnsAcc, inSymJacsAcc);
      then (res, symjacs, countLinearSys, countNonLinSys, countMixedSys, countJacobians);

    case (SimCode.SES_LINEAR(index, partOfMixed, vars, beqs, simJac, eqs, SOME(symJac), sources, _)::rest, _, _, _, _, _, _, _)
      equation
        (eqs, symjacs, countLinearSys, countNonLinSys, countMixedSys, countJacobians) = countandIndexAlgebraicLoopsWork(eqs, {}, inLinearSysIndex+1, inNonLinSysIndex, inMixedSysIndex, inJacobianIndex,  {}, {});
        (symJac, countLinearSys, countNonLinSys, countMixedSys, countJacobians, symjacs) = countandIndexAlgebraicLoopsSymJac(symJac, countLinearSys, countNonLinSys, countMixedSys, countJacobians);
        (res, symjacs, countLinearSys, countNonLinSys, countMixedSys, countJacobians) = countandIndexAlgebraicLoopsWork(rest, listAppend(symjacs,inSymJacs), countLinearSys, countNonLinSys, countMixedSys, countJacobians,  SimCode.SES_LINEAR(index, partOfMixed, vars, beqs, simJac, eqs, SOME(symJac), sources, inLinearSysIndex)::inEqnsAcc, symJac::inSymJacsAcc);
      then (res, symjacs, countLinearSys, countNonLinSys, countMixedSys, countJacobians);

    case (SimCode.SES_MIXED(index, cont, discVars, discEqs, _)::rest, _, _, _, _, _, _, _)
      equation
        ({cont}, _, countLinearSys, countNonLinSys, countMixedSys, countJacobians) = countandIndexAlgebraicLoopsWork({cont}, inSymJacs, inLinearSysIndex, inNonLinSysIndex, inMixedSysIndex, inJacobianIndex, {}, {});
        (res, symjacs, countLinearSys, countNonLinSys, countMixedSys, countJacobians) = countandIndexAlgebraicLoopsWork(rest, {}, countLinearSys, countNonLinSys, countMixedSys+1, countJacobians, SimCode.SES_MIXED(index, cont, discVars, discEqs, inMixedSysIndex)::inEqnsAcc, inSymJacsAcc);
      then (res, symjacs, countLinearSys, countNonLinSys, countMixedSys, countJacobians);

    case (eq::rest, _, _, _, _, _, _, _)
      equation
        (res, symjacs, countLinearSys, countNonLinSys, countMixedSys, countJacobians) = countandIndexAlgebraicLoopsWork(rest, inSymJacs, inLinearSysIndex, inNonLinSysIndex, inMixedSysIndex, inJacobianIndex, eq::inEqnsAcc, inSymJacsAcc);
      then (res, symjacs, countLinearSys, countNonLinSys, countMixedSys, countJacobians);
  end match;
end countandIndexAlgebraicLoopsWork;

protected function countandIndexAlgebraicLoopsSymJac "
  helper function to countandIndexAlgebraicLoops"
  input SimCode.JacobianMatrix inSymjac;
  input Integer inLinearSysIndex;
  input Integer inNonLinSysIndex;
  input Integer inMixedSysIndex;
  input Integer inJacobianIndex;
  output SimCode.JacobianMatrix outSymjac;
  output Integer outLinearSysIndex;
  output Integer outNonLinSysIndex;
  output Integer outMixedSysIndex;
  output Integer outJacobianIndex;
  output list<SimCode.JacobianMatrix> outSymJacs;
protected
  list<SimCode.JacobianColumn> columns;
  list<SimCodeVar.SimVar> vars;
  String str;
  tuple<list<tuple<DAE.ComponentRef,list<DAE.ComponentRef>>>,list<tuple<DAE.ComponentRef,list<DAE.ComponentRef>>>,tuple<list<SimCodeVar.SimVar>,list<SimCodeVar.SimVar>>> tpl;
  list<list<DAE.ComponentRef>> colors;
  Integer maxcolor, index;
algorithm
  (columns, vars, str, tpl, colors, maxcolor, index) := inSymjac;
  (columns, outLinearSysIndex, outNonLinSysIndex, outMixedSysIndex, outJacobianIndex, outSymJacs) := countandIndexAlgebraicLoopsSymJacColumn(columns, inLinearSysIndex, inNonLinSysIndex, inMixedSysIndex, inJacobianIndex, {});
  outSymjac := (columns, vars, str, tpl, colors, maxcolor, outJacobianIndex);
  outJacobianIndex := outJacobianIndex + 1;
end countandIndexAlgebraicLoopsSymJac;

protected function countandIndexAlgebraicLoopsSymJacColumn "
  helper function to countandIndexAlgebraicLoops"
  input list<SimCode.JacobianColumn> inSymColumn;
  input Integer inLinearSysIndex;
  input Integer inNonLinSysIndex;
  input Integer inMixedSysIndex;
  input Integer inJacobianIndex;
  input list<SimCode.JacobianMatrix> inSymJacs;
  output list<SimCode.JacobianColumn> outSymColumn;
  output Integer outLinearSysIndex;
  output Integer outNonLinSysIndex;
  output Integer outMixedSysIndex;
  output Integer outJacobianIndex;
  output list<SimCode.JacobianMatrix> outSymJacs;
algorithm
  (outSymColumn, outLinearSysIndex, outNonLinSysIndex, outMixedSysIndex, outJacobianIndex, outSymJacs) := match(inSymColumn, inLinearSysIndex, inNonLinSysIndex, inMixedSysIndex, inJacobianIndex, inSymJacs)
    local
    list<SimCode.JacobianColumn> rest, result, res1;
    list<SimCode.SimEqSystem> eqns, eqns1;
    list<SimCodeVar.SimVar> vars;
    String str;
    Integer countLinearSys, countNonLinSys, countMixedSys, countJacobians;
    list<SimCode.JacobianMatrix> symJacs;

    case ({}, _, _, _, _, _)
    then ({}, inLinearSysIndex, inNonLinSysIndex, inMixedSysIndex, inJacobianIndex, inSymJacs);

    case ((eqns, vars, str)::rest, _, _, _, _, _) equation
      (eqns1, countLinearSys, countNonLinSys, countMixedSys, countJacobians, symJacs) = countandIndexAlgebraicLoops(eqns, inLinearSysIndex, inNonLinSysIndex, inMixedSysIndex, inJacobianIndex, inSymJacs);
      (res1, countLinearSys, countNonLinSys, countMixedSys, countJacobians, symJacs) = countandIndexAlgebraicLoopsSymJacColumn(rest, countLinearSys, countNonLinSys, countMixedSys, countJacobians, symJacs);
      result = listAppend({(eqns1, vars, str)},res1);
    then (result, countLinearSys, countNonLinSys, countMixedSys, countJacobians, symJacs);
  end match;
end countandIndexAlgebraicLoopsSymJacColumn;

// =============================================================================
// section to create SimCode.Equations from BackendDAE.Equation
//
// =============================================================================

protected function createEquationsForSystems "Some kind of comments would be very helpful!"
  input BackendDAE.EqSystems inSysts;
  input BackendDAE.Shared shared;
  input Integer iuniqueEqIndex;
  input list<list<SimCode.SimEqSystem>> inOdeEquations;
  input list<list<SimCode.SimEqSystem>> inAlgebraicEquations;
  input list<SimCode.SimEqSystem> inAllEquations;
  input list<SimCode.SimEqSystem> inEquationsForZeroCrossings;
  input list<BackendDAE.ZeroCrossing> inAllZeroCrossings;
  input list<SimCodeVar.SimVar> itempvars;
  input Integer isccOffset; //to map the generated equations to the old strongcomponents, they are numbered from (1+offset) to (n+offset)
  input list<tuple<Integer,Integer>> ieqSccMapping;
  input list<tuple<Integer,Integer>> ieqBackendSimCodeMapping;
  input SimCode.BackendMapping iBackendMapping;
  output Integer ouniqueEqIndex;
  output list<list<SimCode.SimEqSystem>> oodeEquations;
  output list<list<SimCode.SimEqSystem>> oalgebraicEquations;
  output list<SimCode.SimEqSystem> oallEquations;
  output list<SimCode.SimEqSystem> oequationsForZeroCrossings;
  output list<SimCodeVar.SimVar> otempvars;
  output list<tuple<Integer,Integer>> oeqSccMapping;
  output list<tuple<Integer,Integer>> oeqBackendSimCodeMapping;
  output SimCode.BackendMapping obackendMapping;
algorithm
  (ouniqueEqIndex, oodeEquations, oalgebraicEquations, oallEquations, oequationsForZeroCrossings, otempvars, oeqSccMapping, oeqBackendSimCodeMapping,obackendMapping) :=
  match (inSysts, shared, iuniqueEqIndex, inOdeEquations, inAlgebraicEquations, inAllEquations, inEquationsForZeroCrossings, inAllZeroCrossings, itempvars, isccOffset, ieqSccMapping, ieqBackendSimCodeMapping, iBackendMapping)
    local
      list<SimCode.SimEqSystem> odeEquations1, algebraicEquations1, allEquations1;
      BackendDAE.StrongComponents comps;
      BackendDAE.EqSystem syst;
      BackendDAE.EqSystems systs;
      list<list<SimCode.SimEqSystem>> odeEquations, algebraicEquations;
      list<SimCode.SimEqSystem> allEquations;
      list<SimCode.SimEqSystem> equationsForZeroCrossings, equationsForZeroCrossings1;
      Integer uniqueEqIndex;
      array<Integer> ass1, stateeqnsmark, zceqnsmarks;
      BackendDAE.Variables vars;
      list<SimCodeVar.SimVar> tempvars;
      DAE.FunctionTree funcs;
      list<tuple<Integer,Integer>> eqSccMapping, tmpEqBackendSimCodeMapping;
      SimCode.BackendMapping tmpBackendMapping;

    case ({}, _, _, _, _, _, _, _, _, _, _, _, _)
    then (iuniqueEqIndex, inOdeEquations, inAlgebraicEquations, inAllEquations, inEquationsForZeroCrossings, itempvars, ieqSccMapping, ieqBackendSimCodeMapping, iBackendMapping);

    case ((syst as BackendDAE.EQSYSTEM(matching=BackendDAE.MATCHING(ass1=ass1, comps=comps)))::systs, _, _, _, _, _, _, _, _, _, _, _, _)
      equation
        funcs = BackendDAEUtil.getFunctions(shared);
        (syst, _, _) = BackendDAEUtil.getIncidenceMatrixfromOption(syst, BackendDAE.ABSOLUTE(), SOME(funcs));
        stateeqnsmark = arrayCreate(BackendDAEUtil.equationArraySizeDAE(syst), 0);
        zceqnsmarks = arrayCreate(BackendDAEUtil.equationArraySizeDAE(syst), 0);
        stateeqnsmark = BackendDAEUtil.markStateEquations(syst, stateeqnsmark, ass1);
        zceqnsmarks = BackendDAEUtil.markZeroCrossingEquations(syst, inAllZeroCrossings, zceqnsmarks, ass1);
        (odeEquations1, algebraicEquations1, allEquations1, equationsForZeroCrossings1, uniqueEqIndex, tempvars, eqSccMapping, tmpEqBackendSimCodeMapping, tmpBackendMapping) =
          createEquationsForSystem1(stateeqnsmark, zceqnsmarks, syst, shared, comps, iuniqueEqIndex, itempvars, isccOffset, ieqSccMapping, ieqBackendSimCodeMapping, iBackendMapping, {}, {}, {}, {});
        odeEquations = List.consOnTrue(not List.isEmpty(odeEquations1),odeEquations1,inOdeEquations);
        algebraicEquations = List.consOnTrue(not List.isEmpty(algebraicEquations1),algebraicEquations1, inAlgebraicEquations);
        allEquations = listAppend(inAllEquations, allEquations1);
        equationsForZeroCrossings = listAppend(inEquationsForZeroCrossings, equationsForZeroCrossings1);
        (uniqueEqIndex, odeEquations, algebraicEquations, allEquations, equationsForZeroCrossings, tempvars, eqSccMapping, tmpEqBackendSimCodeMapping, tmpBackendMapping) =
          createEquationsForSystems(systs, shared, uniqueEqIndex, odeEquations, algebraicEquations, allEquations, equationsForZeroCrossings, inAllZeroCrossings, tempvars, listLength(comps) + isccOffset, eqSccMapping, tmpEqBackendSimCodeMapping, tmpBackendMapping);
     then (uniqueEqIndex, odeEquations, algebraicEquations, allEquations, equationsForZeroCrossings, tempvars, eqSccMapping, tmpEqBackendSimCodeMapping, tmpBackendMapping);
  end match;
end createEquationsForSystems;

protected function createEquationsForSystem1
  input array<Integer> stateeqnsmark;
  input array<Integer> zceqnsmark;
  input BackendDAE.EqSystem syst;
  input BackendDAE.Shared shared;
  input BackendDAE.StrongComponents comps;
  input Integer iuniqueEqIndex;
  input list<SimCodeVar.SimVar> itempvars;
  input Integer isccIndex;
  input list<tuple<Integer,Integer>> ieqSccMapping;
  input list<tuple<Integer,Integer>> ieqBackendSimCodeMapping;
  input SimCode.BackendMapping iBackendMapping;
  input list<list<SimCode.SimEqSystem>> accOdeEquations;
  input list<list<SimCode.SimEqSystem>> accAlgebraicEquations;
  input list<list<SimCode.SimEqSystem>> accAllEquations;
  input list<list<SimCode.SimEqSystem>> accEquationsforZeroCrossings;
  output list<SimCode.SimEqSystem> outOdeEquations;
  output list<SimCode.SimEqSystem> outAlgebraicEquations;
  output list<SimCode.SimEqSystem> outAllEquations;
  output list<SimCode.SimEqSystem> outEquationsforZeroCrossings;
  output Integer ouniqueEqIndex;
  output list<SimCodeVar.SimVar> otempvars;
  output list<tuple<Integer,Integer>> oeqSccMapping;
  output list<tuple<Integer,Integer>> oeqBackendSimCodeMapping;
  output SimCode.BackendMapping oBackendMapping;
algorithm
  (outOdeEquations, outAlgebraicEquations, outAllEquations, outEquationsforZeroCrossings, ouniqueEqIndex, otempvars, oeqSccMapping, oeqBackendSimCodeMapping, oBackendMapping) :=
  match (stateeqnsmark, zceqnsmark, syst, shared, comps, iuniqueEqIndex, itempvars, isccIndex, ieqSccMapping, ieqBackendSimCodeMapping, iBackendMapping, accOdeEquations, accAlgebraicEquations, accAllEquations, accEquationsforZeroCrossings)
    local
      BackendDAE.StrongComponent comp;
      BackendDAE.StrongComponents restComps;
      Integer e, index, vindex, uniqueEqIndex, firstEqIndex;
      BackendDAE.Variables vars;
      BackendDAE.EquationArray eqns;
      BackendDAE.Var v;
      BackendDAE.Equation eqn;
      SimCode.SimEqSystem firstSES;
      list<BackendDAE.Equation> eqnlst;
      list<BackendDAE.Var> varlst;
      list<Integer> eqnslst;
      list<SimCode.SimEqSystem> equations1, noDiscEquations1;
      Boolean bwhen, bdisc, bdynamic, isEqSys, bzceqns;
      list<SimCodeVar.SimVar> tempvars;
      String message;
      list<tuple<Integer,Integer>> tmpEqSccMapping, tmpEqBackendSimCodeMapping;
      BackendDAE.ExtraInfo ei;
      SimCode.BackendMapping tmpBackendMapping;
      list<list<SimCode.SimEqSystem>> odeEquations,algebraicEquations,allEquations,equationsforZeroCrossings;

    // handle empty
    case (_, _, _, _, {}, _, _, _,_, _, _, odeEquations, algebraicEquations, allEquations, equationsforZeroCrossings)
      equation
        outOdeEquations = List.flatten(listReverse(odeEquations));
        outAlgebraicEquations = List.flatten(listReverse(algebraicEquations));
        outAllEquations = List.flatten(listReverse(allEquations));
        outEquationsforZeroCrossings = List.flatten(listReverse(equationsforZeroCrossings));
      then (outOdeEquations, outAlgebraicEquations, outAllEquations, outEquationsforZeroCrossings, iuniqueEqIndex, itempvars, ieqSccMapping, ieqBackendSimCodeMapping, iBackendMapping);

    // single equation
    case (_, _, _, _, comp::restComps, _, _, _, _, _, _, odeEquations, algebraicEquations, allEquations, equationsforZeroCrossings)
      equation
        (odeEquations, algebraicEquations, allEquations, equationsforZeroCrossings, uniqueEqIndex, tempvars, tmpEqSccMapping, tmpEqBackendSimCodeMapping, tmpBackendMapping) =
          createEquationsForSystem2(stateeqnsmark, zceqnsmark, syst, shared, comp, iuniqueEqIndex, itempvars, isccIndex, ieqSccMapping, ieqBackendSimCodeMapping, iBackendMapping, odeEquations, algebraicEquations, allEquations, equationsforZeroCrossings);
        (outOdeEquations, outAlgebraicEquations, outAllEquations, outEquationsforZeroCrossings, uniqueEqIndex, tempvars, tmpEqSccMapping, tmpEqBackendSimCodeMapping, tmpBackendMapping) =
          createEquationsForSystem1(stateeqnsmark, zceqnsmark, syst, shared, restComps, uniqueEqIndex, tempvars, isccIndex+1, tmpEqSccMapping, tmpEqBackendSimCodeMapping, tmpBackendMapping, odeEquations, algebraicEquations, allEquations, equationsforZeroCrossings);

      then
        (outOdeEquations, outAlgebraicEquations, outAllEquations, outEquationsforZeroCrossings, uniqueEqIndex, tempvars, tmpEqSccMapping, tmpEqBackendSimCodeMapping, tmpBackendMapping);
  end match;
end createEquationsForSystem1;

protected function createEquationsForSystem2
  input array<Integer> stateeqnsmark;
  input array<Integer> zceqnsmark;
  input BackendDAE.EqSystem syst;
  input BackendDAE.Shared shared;
  input BackendDAE.StrongComponent comp;
  input Integer iuniqueEqIndex;
  input list<SimCodeVar.SimVar> itempvars;
  input Integer isccIndex;
  input list<tuple<Integer,Integer>> ieqSccMapping;
  input list<tuple<Integer,Integer>> ieqBackendSimCodeMapping;
  input SimCode.BackendMapping iBackendMapping;
  input list<list<SimCode.SimEqSystem>> accOdeEquations;
  input list<list<SimCode.SimEqSystem>> accAlgebraicEquations;
  input list<list<SimCode.SimEqSystem>> accAllEquations;
  input list<list<SimCode.SimEqSystem>> accEquationsforZeroCrossings;
  output list<list<SimCode.SimEqSystem>> odeEquations;
  output list<list<SimCode.SimEqSystem>> algebraicEquations;
  output list<list<SimCode.SimEqSystem>> allEquations;
  output list<list<SimCode.SimEqSystem>> equationsforZeroCrossings;
  output Integer ouniqueEqIndex;
  output list<SimCodeVar.SimVar> otempvars;
  output list<tuple<Integer,Integer>> oeqSccMapping;
  output list<tuple<Integer,Integer>> oeqBackendSimCodeMapping;
  output SimCode.BackendMapping oBackendMapping;
algorithm
  (odeEquations, algebraicEquations, allEquations, equationsforZeroCrossings, ouniqueEqIndex, otempvars, oeqSccMapping, oeqBackendSimCodeMapping, oBackendMapping) :=
  matchcontinue (stateeqnsmark, zceqnsmark, syst, shared, comp, iuniqueEqIndex, itempvars, isccIndex, ieqSccMapping, ieqBackendSimCodeMapping, iBackendMapping, accOdeEquations, accAlgebraicEquations, accAllEquations, accEquationsforZeroCrossings)
    local
      BackendDAE.StrongComponents restComps;
      Integer e, index, vindex, uniqueEqIndex, firstEqIndex;
      BackendDAE.Variables vars;
      BackendDAE.EquationArray eqns;
      BackendDAE.Var v;
      BackendDAE.Equation eqn;
      SimCode.SimEqSystem firstSES;
      list<BackendDAE.Equation> eqnlst;
      list<BackendDAE.Var> varlst;
      list<Integer> eqnslst;
      list<SimCode.SimEqSystem> equations1, noDiscEquations1;
      Boolean bwhen, bdisc, bdynamic, isEqSys, bzceqns;
      list<SimCodeVar.SimVar> tempvars;
      String message;
      list<tuple<Integer,Integer>> tmpEqSccMapping, tmpEqBackendSimCodeMapping;
      BackendDAE.ExtraInfo ei;
      SimCode.BackendMapping tmpBackendMapping;

    // single equation
    case (_, _, BackendDAE.EQSYSTEM(orderedVars=vars, orderedEqs=eqns), _, (BackendDAE.SINGLEEQUATION(eqn=index, var=vindex)), _, _, _, _, _, _, odeEquations, algebraicEquations, allEquations, equationsforZeroCrossings)
      equation
        eqn = BackendEquation.equationNth1(eqns, index);
        // ignore when equations if we should not generate them
        bwhen = BackendEquation.isWhenEquation(eqn);
        // ignore discrete if we should not generate them
        v = BackendVariable.getVarAt(vars, index);
        _ = BackendVariable.isVarDiscrete(v);
        // block is dynamic, belong in dynamic section
        bdynamic = BackendDAEUtil.blockIsDynamic({index}, stateeqnsmark);
        // block need to evaluate zeroCrossings
        bzceqns = BackendDAEUtil.blockIsDynamic({index}, zceqnsmark);
        (equations1, uniqueEqIndex, tempvars) = createEquation(index, vindex, syst, shared, false, iuniqueEqIndex, itempvars);

        firstSES = List.first(equations1);  // check if the all equations occure with this index in the c file
        isEqSys = isSimEqSys(firstSES);
        firstEqIndex = if isEqSys then uniqueEqIndex-1 else iuniqueEqIndex;
        //tmpEqSccMapping = List.fold1(List.intRange2(iuniqueEqIndex, uniqueEqIndex - 1), appendSccIdx, isccIndex, ieqSccMapping);

        tmpEqSccMapping = List.fold1(List.intRange2(firstEqIndex, uniqueEqIndex - 1), appendSccIdx, isccIndex, ieqSccMapping);
        tmpEqBackendSimCodeMapping = List.fold1(List.intRange2(firstEqIndex, uniqueEqIndex - 1), appendSccIdx, index, ieqBackendSimCodeMapping);
        tmpBackendMapping = setEqMapping(List.intRange2(firstEqIndex, uniqueEqIndex - 1),{index}, iBackendMapping);

        odeEquations = if bdynamic and (not bwhen) then equations1::odeEquations else odeEquations;
        algebraicEquations = if (not bdynamic) and (not bwhen) then equations1::algebraicEquations else algebraicEquations;
        equationsforZeroCrossings = if bzceqns and (not bwhen) then equations1::equationsforZeroCrossings else equationsforZeroCrossings;
        allEquations = equations1::allEquations;
      then
        (odeEquations, algebraicEquations, allEquations, equationsforZeroCrossings, uniqueEqIndex, tempvars, tmpEqSccMapping, tmpEqBackendSimCodeMapping, tmpBackendMapping);

    // A single array equation
    case (_, _, BackendDAE.EQSYSTEM(orderedVars=vars, orderedEqs=eqns),
          BackendDAE.SHARED(info = ei), BackendDAE.SINGLEARRAY(eqn=e), _, _, _, _, _, _, odeEquations, algebraicEquations, allEquations, equationsforZeroCrossings)
      equation
        // block is dynamic, belong in dynamic section
        bdynamic = BackendDAEUtil.blockIsDynamic({e}, stateeqnsmark);
        // block need to evaluate zeroCrossings
        bzceqns = BackendDAEUtil.blockIsDynamic({e}, zceqnsmark);

        (eqnlst, varlst,_) = BackendDAETransform.getEquationAndSolvedVar(comp, eqns, vars);
        // States are solved for der(x) not x.
        varlst = List.map(varlst, BackendVariable.transformXToXd);
        (equations1, noDiscEquations1, uniqueEqIndex, tempvars) = createSingleArrayEqnCode(true, eqnlst, varlst, iuniqueEqIndex, itempvars, ei);

        tmpEqSccMapping = List.fold1(List.intRange2(iuniqueEqIndex, uniqueEqIndex - 1), appendSccIdx, isccIndex, ieqSccMapping);
        tmpEqBackendSimCodeMapping = List.fold1(List.intRange2(iuniqueEqIndex, uniqueEqIndex - 1), appendSccIdx, e, ieqBackendSimCodeMapping);
        tmpBackendMapping = iBackendMapping;

        odeEquations = if bdynamic then noDiscEquations1::odeEquations else odeEquations;
        algebraicEquations = if not bdynamic then noDiscEquations1::algebraicEquations else algebraicEquations;
        equationsforZeroCrossings = if bzceqns then noDiscEquations1::equationsforZeroCrossings else equationsforZeroCrossings;
        allEquations = equations1::allEquations;
      then
        (odeEquations, algebraicEquations, allEquations, equationsforZeroCrossings, uniqueEqIndex, tempvars, tmpEqSccMapping, tmpEqBackendSimCodeMapping, tmpBackendMapping);

    // A single algorithm section for several variables.
    case (_, _, BackendDAE.EQSYSTEM(orderedVars=vars, orderedEqs=eqns), _, BackendDAE.SINGLEALGORITHM(eqn=e), _, _, _, _, _, _, odeEquations, algebraicEquations, allEquations, equationsforZeroCrossings)
      equation
        // block is dynamic, belong in dynamic section
        bdynamic = BackendDAEUtil.blockIsDynamic({e}, stateeqnsmark);
        // block need to evaluate zeroCrossings
        bzceqns = BackendDAEUtil.blockIsDynamic({e}, zceqnsmark);

        (eqnlst, varlst, _) = BackendDAETransform.getEquationAndSolvedVar(comp, eqns, vars);
        varlst = List.map(varlst, BackendVariable.transformXToXd);
        (equations1, uniqueEqIndex) = createSingleAlgorithmCode(eqnlst, varlst, false, iuniqueEqIndex);

        tmpEqSccMapping = List.fold1(List.intRange2(iuniqueEqIndex, uniqueEqIndex - 1), appendSccIdx, isccIndex, ieqSccMapping);
        tmpEqBackendSimCodeMapping = List.fold1(List.intRange2(iuniqueEqIndex, uniqueEqIndex - 1), appendSccIdx, e, ieqBackendSimCodeMapping);
        tmpBackendMapping = iBackendMapping;

        odeEquations = if bdynamic then equations1::odeEquations else odeEquations;
        algebraicEquations = if not bdynamic then equations1::algebraicEquations else algebraicEquations;
        equationsforZeroCrossings = if bzceqns then equations1::equationsforZeroCrossings else equationsforZeroCrossings;
        allEquations = equations1::allEquations;
      then
        (odeEquations, algebraicEquations, allEquations, equationsforZeroCrossings, uniqueEqIndex, itempvars, tmpEqSccMapping, tmpEqBackendSimCodeMapping, tmpBackendMapping);

    // A single complex equation
    case (_, _, BackendDAE.EQSYSTEM(orderedVars=vars, orderedEqs=eqns), _, BackendDAE.SINGLECOMPLEXEQUATION(eqn=e), _, _, _, _, _, _, odeEquations, algebraicEquations, allEquations, equationsforZeroCrossings)
      equation
        // block is dynamic, belong in dynamic section
        bdynamic = BackendDAEUtil.blockIsDynamic({e}, stateeqnsmark);
        // block need to evaluate zeroCrossings
        bzceqns = BackendDAEUtil.blockIsDynamic({e}, zceqnsmark);

        (eqnlst, varlst,_) = BackendDAETransform.getEquationAndSolvedVar(comp, eqns, vars);
        // States are solved for der(x) not x.
        varlst = List.map(varlst, BackendVariable.transformXToXd);
        (equations1, uniqueEqIndex, tempvars) = createSingleComplexEqnCode(listGet(eqnlst, 1), varlst, iuniqueEqIndex, itempvars);

        tmpEqSccMapping = appendSccIdx(uniqueEqIndex-1, isccIndex, ieqSccMapping);
        tmpEqBackendSimCodeMapping = List.fold1(List.intRange2(iuniqueEqIndex, uniqueEqIndex - 1), appendSccIdx, e, ieqBackendSimCodeMapping);
        tmpBackendMapping = iBackendMapping;

        odeEquations = if bdynamic then equations1::odeEquations else odeEquations;
        algebraicEquations = if not bdynamic then equations1::algebraicEquations else algebraicEquations;
        equationsforZeroCrossings = if bzceqns then equations1::equationsforZeroCrossings else equationsforZeroCrossings;
        allEquations = equations1::allEquations;
      then
        (odeEquations, algebraicEquations, allEquations, equationsforZeroCrossings, uniqueEqIndex, tempvars, tmpEqSccMapping, tmpEqBackendSimCodeMapping, tmpBackendMapping);

    // A single when equation
    case (_, _, BackendDAE.EQSYSTEM(orderedVars=vars, orderedEqs=eqns), _, BackendDAE.SINGLEWHENEQUATION(eqn=e), _, _, _, _, _, _, odeEquations, algebraicEquations, allEquations, equationsforZeroCrossings)
      equation
        // block is dynamic, belong in dynamic section
        _ = BackendDAEUtil.blockIsDynamic({e}, stateeqnsmark);
        // block need to evaluate zeroCrossings
        _ = BackendDAEUtil.blockIsDynamic({e}, zceqnsmark);

        (eqnlst, varlst, index) = BackendDAETransform.getEquationAndSolvedVar(comp, eqns, vars);
        // States are solved for der(x) not x.
        varlst = List.map(varlst, BackendVariable.transformXToXd);
        (equations1, uniqueEqIndex, tempvars) = createSingleWhenEqnCode(listGet(eqnlst, 1), varlst, shared, iuniqueEqIndex, itempvars);

        tmpEqSccMapping = List.fold1(List.intRange2(iuniqueEqIndex, uniqueEqIndex - 1), appendSccIdx, isccIndex, ieqSccMapping);
        tmpEqBackendSimCodeMapping = List.fold1(List.intRange2(iuniqueEqIndex, uniqueEqIndex - 1), appendSccIdx, index, ieqBackendSimCodeMapping);
        tmpBackendMapping = iBackendMapping;

        allEquations = equations1::allEquations;
      then
        (odeEquations, algebraicEquations, allEquations, equationsforZeroCrossings, uniqueEqIndex, tempvars, tmpEqSccMapping, tmpEqBackendSimCodeMapping, tmpBackendMapping);

    // A single if equation
    case (_, _, BackendDAE.EQSYSTEM(orderedVars=vars, orderedEqs=eqns), _, BackendDAE.SINGLEIFEQUATION(eqn=e), _, _, _, _, _, _, odeEquations, algebraicEquations, allEquations, equationsforZeroCrossings)
      equation
        // block is dynamic, belong in dynamic section
        bdynamic = BackendDAEUtil.blockIsDynamic({e}, stateeqnsmark);
        // block need to evaluate zeroCrossings
        bzceqns = BackendDAEUtil.blockIsDynamic({e}, zceqnsmark);

        (eqnlst, varlst, index) = BackendDAETransform.getEquationAndSolvedVar(comp, eqns, vars);
        // States are solved for der(x) not x.
        varlst = List.map(varlst, BackendVariable.transformXToXd);
        (equations1, uniqueEqIndex, tempvars) = createSingleIfEqnCode(listGet(eqnlst, 1), varlst, shared, true, iuniqueEqIndex, itempvars);

        tmpEqSccMapping = List.fold1(List.intRange2(iuniqueEqIndex, uniqueEqIndex - 1), appendSccIdx, isccIndex, ieqSccMapping);
        tmpEqBackendSimCodeMapping = List.fold1(List.intRange2(iuniqueEqIndex, uniqueEqIndex - 1), appendSccIdx, index, ieqBackendSimCodeMapping);
        tmpBackendMapping = iBackendMapping;

        odeEquations = if bdynamic then equations1::odeEquations else odeEquations;
        algebraicEquations = if not bdynamic then equations1::algebraicEquations else algebraicEquations;
        equationsforZeroCrossings = if bzceqns then equations1::equationsforZeroCrossings else equationsforZeroCrossings;
        allEquations = equations1::allEquations;
      then
        (odeEquations, algebraicEquations, allEquations, equationsforZeroCrossings, uniqueEqIndex, tempvars, tmpEqSccMapping, tmpEqBackendSimCodeMapping, tmpBackendMapping);

    // a system of equations
    case (_, _, _, _, _, _, _, _, _, _, _, odeEquations, algebraicEquations, allEquations, equationsforZeroCrossings)
      equation
        // block is dynamic, belong in dynamic section
        (eqnslst, _) = BackendDAETransform.getEquationAndSolvedVarIndxes(comp);
        bdynamic = BackendDAEUtil.blockIsDynamic(eqnslst, stateeqnsmark);
        // block need to evaluate zeroCrossings
        bzceqns = BackendDAEUtil.blockIsDynamic(eqnslst, zceqnsmark);

        (equations1, noDiscEquations1, uniqueEqIndex, tempvars, tmpEqSccMapping, tmpBackendMapping) =
          createOdeSystem(true, false, syst, shared, comp, iuniqueEqIndex, itempvars, isccIndex, ieqSccMapping, iBackendMapping);
        //tmpEqSccMapping = List.fold1(List.intRange2(iuniqueEqIndex, uniqueEqIndex - 1), appendSccIdx, isccIndex, ieqSccMapping);

        odeEquations = if bdynamic then noDiscEquations1::odeEquations else odeEquations;
        algebraicEquations = if not bdynamic then noDiscEquations1::algebraicEquations else algebraicEquations;
        equationsforZeroCrossings = if bzceqns then noDiscEquations1::equationsforZeroCrossings else equationsforZeroCrossings;
        allEquations = equations1::allEquations;
      then
        (odeEquations, algebraicEquations, allEquations, equationsforZeroCrossings, uniqueEqIndex, tempvars, tmpEqSccMapping, ieqBackendSimCodeMapping, tmpBackendMapping);

    // detailed error message
    else
      equation
        message = "function createEquationsForSystem1 failed for component " + BackendDump.strongComponentString(comp);
        Error.addMessage(Error.INTERNAL_ERROR, {message});
      then fail();

  end matchcontinue;
end createEquationsForSystem2;

protected function appendSccIdx
  input Integer iCurrentIdx;
  input Integer iSccIdx;
  input list<tuple<Integer,Integer>> iSccIdc;
  output list<tuple<Integer,Integer>> oSccIdc;
algorithm
  oSccIdc := ((iCurrentIdx,iSccIdx))::iSccIdc;
end appendSccIdx;

protected function createEquations
  input Boolean includeWhen;
  input Boolean skipDiscInZc;
  input Boolean genDiscrete;
  input Boolean skipDiscInAlgorithm;
  input BackendDAE.EqSystem syst;
  input BackendDAE.Shared shared;
  input BackendDAE.StrongComponents comps;
  input Integer iuniqueEqIndex;
  input list<SimCodeVar.SimVar> itempvars;
  output list<SimCode.SimEqSystem> equations;
  output list<SimCode.SimEqSystem> noDiscEquations;
  output Integer ouniqueEqIndex;
  output list<SimCodeVar.SimVar> otempvars;
algorithm
  (equations, noDiscEquations, ouniqueEqIndex, otempvars) := createEquations1(includeWhen, skipDiscInZc, genDiscrete, skipDiscInAlgorithm, syst, shared, comps, iuniqueEqIndex, itempvars, {}, {});
end createEquations;

protected function createEquations1
  input Boolean includeWhen;
  input Boolean skipDiscInZc;
  input Boolean genDiscrete;
  input Boolean skipDiscInAlgorithm;
  input BackendDAE.EqSystem syst;
  input BackendDAE.Shared shared;
  input BackendDAE.StrongComponents comps;
  input Integer iuniqueEqIndex;
  input list<SimCodeVar.SimVar> itempvars;
  input list<list<SimCode.SimEqSystem>> accEquations;
  input list<list<SimCode.SimEqSystem>> accNoDiscEquations;
  output list<SimCode.SimEqSystem> equations;
  output list<SimCode.SimEqSystem> noDiscEquations;
  output Integer ouniqueEqIndex;
  output list<SimCodeVar.SimVar> otempvars;
algorithm
  (equations, noDiscEquations, ouniqueEqIndex, otempvars) := match (includeWhen, skipDiscInZc, genDiscrete, skipDiscInAlgorithm, syst, shared, comps, iuniqueEqIndex, itempvars, accEquations, accNoDiscEquations)
    local
      BackendDAE.StrongComponent comp;
      BackendDAE.StrongComponents restComps;
      Integer index, vindex, uniqueEqIndex;
      BackendDAE.Variables vars;
      BackendDAE.EquationArray eqns;
      BackendDAE.Var v;
      list<BackendDAE.Equation> eqnlst;
      list<BackendDAE.Var> varlst;
      list<Integer> zcEqns;
      list<SimCode.SimEqSystem> equations_, equations1, noDiscEquations1;
      list<SimCodeVar.SimVar> tempvars;
      BackendDAE.ExtraInfo ei;

      // handle empty
    case (_, _, _, _, _, _, {}, _, _, _, _) then (List.flatten(listReverse(accEquations)), List.flatten(listReverse(accNoDiscEquations)), iuniqueEqIndex, itempvars);

      // ignore when equations if we should not generate them
    case (_, _, _, _, _, _, comp :: restComps, _, _, _, _)
      equation
        (equations, noDiscEquations, uniqueEqIndex, tempvars) = createEquationsWork(includeWhen, skipDiscInZc, genDiscrete, skipDiscInAlgorithm, syst, shared, comp, iuniqueEqIndex, itempvars);
        (equations, noDiscEquations, uniqueEqIndex, tempvars) = createEquations1(false, skipDiscInZc, genDiscrete, skipDiscInAlgorithm, syst, shared, restComps, uniqueEqIndex, tempvars, equations::accEquations, noDiscEquations::accNoDiscEquations);
      then (equations, noDiscEquations, uniqueEqIndex, tempvars);
  end match;
end createEquations1;

protected function createEquationsWork
  input Boolean includeWhen;
  input Boolean skipDiscInZc;
  input Boolean genDiscrete;
  input Boolean skipDiscInAlgorithm;
  input BackendDAE.EqSystem syst;
  input BackendDAE.Shared shared;
  input BackendDAE.StrongComponent comp;
  input Integer iuniqueEqIndex;
  input list<SimCodeVar.SimVar> itempvars;
  output list<SimCode.SimEqSystem> equations;
  output list<SimCode.SimEqSystem> noDiscEquations;
  output Integer ouniqueEqIndex;
  output list<SimCodeVar.SimVar> otempvars;
algorithm
  (equations, noDiscEquations, ouniqueEqIndex, otempvars) := matchcontinue (includeWhen, skipDiscInZc, genDiscrete, skipDiscInAlgorithm, syst, shared, comp, iuniqueEqIndex, itempvars)
    local
      Integer index, vindex, uniqueEqIndex;
      BackendDAE.Variables vars;
      BackendDAE.EquationArray eqns;
      BackendDAE.Var v;
      list<BackendDAE.Equation> eqnlst;
      list<BackendDAE.Var> varlst;
      list<Integer> zcEqns;
      list<SimCode.SimEqSystem> equations_, equations1, noDiscEquations1;
      list<SimCodeVar.SimVar> tempvars;
      BackendDAE.ExtraInfo ei;

      // ignore when equations if we should not generate them
    case (false, _, _, _, BackendDAE.EQSYSTEM(orderedEqs=eqns), _, BackendDAE.SINGLEEQUATION(eqn=index), _, _)
      equation
        BackendDAE.WHEN_EQUATION() = BackendEquation.equationNth1(eqns, index);
      then ({}, {}, iuniqueEqIndex, itempvars);

    case (false, _, _, _, BackendDAE.EQSYSTEM(), _, BackendDAE.SINGLEWHENEQUATION(), _, _)
      then ({}, {}, iuniqueEqIndex, itempvars);

        // ignore discrete if we should not generate them
    case (_, _, false, _, BackendDAE.EQSYSTEM(orderedVars=vars), _, BackendDAE.SINGLEEQUATION(var=index), _, _)
      equation
        v = BackendVariable.getVarAt(vars, index);
        true = BackendVariable.isVarDiscrete(v);
      then ({}, {}, iuniqueEqIndex, itempvars);
    case (_, _, false, _, BackendDAE.EQSYSTEM(), _, BackendDAE.SINGLEWHENEQUATION(), _, _)
      then ({}, {}, iuniqueEqIndex, itempvars);

        // ignore discrete in zero crossing if we should not generate them
    case (_, true, _, _, BackendDAE.EQSYSTEM(orderedVars=vars), _, BackendDAE.SINGLEEQUATION(eqn=index, var=vindex), _, _)
      equation
        v = BackendVariable.getVarAt(vars, vindex);
        true = BackendVariable.isVarDiscrete(v);
        zcEqns = zeroCrossingsEquations(syst, shared);
        true = listMember(index, zcEqns);
      then ({}, {}, iuniqueEqIndex, itempvars);

        // single equation
    case (_, _, _, _, _, _, BackendDAE.SINGLEEQUATION(eqn=index, var=vindex), _, _)
      equation
        (equations1, uniqueEqIndex, tempvars) = createEquation(index, vindex, syst, shared, skipDiscInAlgorithm, iuniqueEqIndex, itempvars);
      then (equations1, equations1, uniqueEqIndex, tempvars);

      // A single array equation
    case (_, _, _, _, BackendDAE.EQSYSTEM(orderedVars=vars, orderedEqs=eqns), BackendDAE.SHARED(info = ei), BackendDAE.SINGLEARRAY(), _, _)
      equation
        (eqnlst, varlst,_) = BackendDAETransform.getEquationAndSolvedVar(comp, eqns, vars);
        // States are solved for der(x) not x.
        varlst = List.map(varlst, BackendVariable.transformXToXd);
        (equations1, noDiscEquations1, uniqueEqIndex, tempvars) = createSingleArrayEqnCode(genDiscrete, eqnlst, varlst, iuniqueEqIndex, itempvars, ei);
      then (equations1, noDiscEquations1, uniqueEqIndex, tempvars);

        // A single algorithm section for several variables.
    case (_, _, _, _, BackendDAE.EQSYSTEM(orderedVars=vars, orderedEqs=eqns), _, BackendDAE.SINGLEALGORITHM(), _, _)
      equation
        (eqnlst, varlst, _) = BackendDAETransform.getEquationAndSolvedVar(comp, eqns, vars);
        varlst = List.map(varlst, BackendVariable.transformXToXd);
        (equations1, uniqueEqIndex) = createSingleAlgorithmCode(eqnlst, varlst, skipDiscInAlgorithm, iuniqueEqIndex);
      then (equations1, equations1, uniqueEqIndex, itempvars);

      // A single complex equation
    case (_, _, _, _, BackendDAE.EQSYSTEM(orderedVars=vars, orderedEqs=eqns), _, BackendDAE.SINGLECOMPLEXEQUATION(), _, _)
      equation
        (eqnlst, varlst,_) = BackendDAETransform.getEquationAndSolvedVar(comp, eqns, vars);
        // States are solved for der(x) not x.
        varlst = List.map(varlst, BackendVariable.transformXToXd);
        (equations1, uniqueEqIndex, tempvars) = createSingleComplexEqnCode(listGet(eqnlst, 1), varlst, iuniqueEqIndex, itempvars);
      then (equations1, equations1, uniqueEqIndex, tempvars);

    // A single when equation
    case (_, _, _, _, BackendDAE.EQSYSTEM(orderedVars=vars, orderedEqs=eqns), _, BackendDAE.SINGLEWHENEQUATION(), _, _)
      equation
        (eqnlst, varlst,_) = BackendDAETransform.getEquationAndSolvedVar(comp, eqns, vars);
        // States are solved for der(x) not x.
        varlst = List.map(varlst, BackendVariable.transformXToXd);
        (equations1, uniqueEqIndex, tempvars) = createSingleWhenEqnCode(listGet(eqnlst, 1), varlst, shared, iuniqueEqIndex, itempvars);
      then (equations1, equations1, uniqueEqIndex, tempvars);

    // A single if equation
    case (_, _, _, _, BackendDAE.EQSYSTEM(orderedVars=vars, orderedEqs=eqns), _, BackendDAE.SINGLEIFEQUATION(), _, _)
      equation
        (eqnlst, varlst,_) = BackendDAETransform.getEquationAndSolvedVar(comp, eqns, vars);
        // States are solved for der(x) not x.
        varlst = List.map(varlst, BackendVariable.transformXToXd);
        (equations1, uniqueEqIndex, tempvars) = createSingleIfEqnCode(listGet(eqnlst, 1), varlst, shared, genDiscrete, iuniqueEqIndex, itempvars);
      then (equations1, equations1, uniqueEqIndex, tempvars);

    // a system of equations
    case (_, _, _, _, _, _, _, _, _)
      equation
        (equations1, noDiscEquations1, uniqueEqIndex, tempvars, _, _) = createOdeSystem(genDiscrete, skipDiscInAlgorithm, syst, shared, comp, iuniqueEqIndex, itempvars, 1, {}, SimCode.NO_MAPPING());
      then (equations1, noDiscEquations1, uniqueEqIndex, tempvars);

    // failure
    else equation
      Error.addMessage(Error.INTERNAL_ERROR, {"createEquation failed"});
    then fail();
  end matchcontinue;
end createEquationsWork;

// =============================================================================
// section for zeroCrossingsEquations
//
// =============================================================================

protected function zeroCrossingsEquations "
  Returns a list of all equations (by their index) that contain a zero crossing
  Used e.g. to find out which discrete equations are not part of a zero crossing"
  input BackendDAE.EqSystem syst;
  input BackendDAE.Shared shared;
  output list<Integer> eqns;
protected
  list<BackendDAE.ZeroCrossing> zeroCrossingLst;
  list<list<Integer>> zcEqns;
  list<Integer> wcEqns;
  BackendDAE.EquationArray orderedEqs;
algorithm
  BackendDAE.EQSYSTEM(orderedEqs=orderedEqs) := syst;
  BackendDAE.SHARED(eventInfo=BackendDAE.EVENT_INFO(zeroCrossingLst=zeroCrossingLst)) := shared;
  zcEqns := List.map(zeroCrossingLst, zeroCrossingEquations);
  wcEqns := whenEquationsIndices(orderedEqs);
  eqns := List.unionList(listAppend(zcEqns, {wcEqns}));
end zeroCrossingsEquations;

protected function zeroCrossingEquations "
  Returns the list of equations (indices) from a ZeroCrossing"
  input BackendDAE.ZeroCrossing inZC;
  output list<Integer> outLst;
algorithm
  BackendDAE.ZERO_CROSSING(_, outLst, _) := inZC;
end zeroCrossingEquations;

protected function whenEquationsIndices "
  Returns all equation-indices that contain a when clause"
  input BackendDAE.EquationArray eqns;
  output list<Integer> res;
algorithm
  res := whenEquationsIndices2(1, BackendDAEUtil.equationArraySize(eqns), eqns);
end whenEquationsIndices;

protected function whenEquationsIndices2
  input Integer i;
  input Integer size;
  input BackendDAE.EquationArray eqns;
  output list<Integer> eqnLst;
algorithm
  eqnLst := matchcontinue(i, size, eqns)
    case(_, _, _)
      equation
        true = (i > size );
      then {};
    case(_, _, _)
      equation
        BackendDAE.WHEN_EQUATION() = BackendEquation.equationNth1(eqns, i);
        eqnLst = whenEquationsIndices2(i+1, size, eqns);
      then i::eqnLst;
    case(_, _, _)
      equation
        eqnLst=whenEquationsIndices2(i+1, size, eqns);
      then eqnLst;
  end matchcontinue;
end whenEquationsIndices2;

protected function updateZeroCrossEqnIndex
  input list<BackendDAE.ZeroCrossing> izeroCrossings;
  input list<tuple<Integer, Integer>> eqBackendSimCodeMapping;
  input Integer numEqnsinArray;
  output list<BackendDAE.ZeroCrossing> ozeroCrossings;
protected
  array<Integer> mappingArray;
algorithm
  mappingArray := convertListMappingToArray(eqBackendSimCodeMapping, numEqnsinArray);
  ozeroCrossings := updateZeroCrossEqnIndexHelp(izeroCrossings, mappingArray, {});
end updateZeroCrossEqnIndex;

protected function updateZeroCrossEqnIndexHelp
  input list<BackendDAE.ZeroCrossing> izeroCrossings;
  input array<Integer> eqBackendSimCodeMappingArray;
  input list<BackendDAE.ZeroCrossing> iAccum;
  output list<BackendDAE.ZeroCrossing> ozeroCrossings;
algorithm
 ozeroCrossings := match(izeroCrossings, eqBackendSimCodeMappingArray, iAccum)
 local
    DAE.Exp exp;
    list<Integer> occurEquLst;
    list<Integer> occurWhenLst;
    list<BackendDAE.ZeroCrossing> rest;

   case ({}, _, _) then listReverse(iAccum);

   case (BackendDAE.ZERO_CROSSING(relation_=exp, occurEquLst=occurEquLst, occurWhenLst=occurWhenLst)::rest, _, _)
     equation
       occurEquLst = convertListIndx(occurEquLst, eqBackendSimCodeMappingArray);
       occurWhenLst = convertListIndx(occurWhenLst, eqBackendSimCodeMappingArray);
       ozeroCrossings = updateZeroCrossEqnIndexHelp(rest, eqBackendSimCodeMappingArray, BackendDAE.ZERO_CROSSING(exp, occurEquLst, occurWhenLst)::iAccum);
     then
       ozeroCrossings;

  end match;
end updateZeroCrossEqnIndexHelp;

protected function convertListMappingToArray
  input list<tuple<Integer,Integer>> iMapping; //<simEqIdx,BackendEqnIndx>
  input Integer numOfBackendEqs;
  output array<Integer> oMapping;
algorithm
  oMapping := arrayCreate(numOfBackendEqs, -1);
  oMapping := List.fold(iMapping, convertListMappingToArray1, oMapping);
end convertListMappingToArray;

protected function convertListMappingToArray1
  input tuple<Integer,Integer> iMapping; //<simEqIdx,BackendEqnIndx>
  input array<Integer> iMappingArray;
  output array<Integer> oMappingArray;
protected
  Integer simEqIdx,BackendEqnIdx;
algorithm
  (simEqIdx,BackendEqnIdx) := iMapping;
  oMappingArray := arrayUpdate(iMappingArray,BackendEqnIdx,simEqIdx);
end convertListMappingToArray1;

protected function convertListIndx
  input list<Integer> iIntList;
  input array<Integer> iMappingArray;
  output list<Integer> oIntList;
algorithm
  oIntList := List.map1r(iIntList, arrayGet, iMappingArray);
end convertListIndx;

protected function addAssertEqn
  input list<DAE.Statement> asserts;
  input list<SimCode.SimEqSystem> iequations;
  input Integer iuniqueEqIndex;
  output list<SimCode.SimEqSystem> oequations;
  output Integer ouniqueEqIndex;
algorithm
  (oequations, ouniqueEqIndex) := match(asserts, iequations, iuniqueEqIndex)
    case({}, _, _) then (iequations, iuniqueEqIndex);
    else
     then
       (SimCode.SES_ALGORITHM(iuniqueEqIndex, asserts)::iequations, iuniqueEqIndex+1);
  end match;
end addAssertEqn;

protected function createEquation
  input Integer eqNum;
  input Integer varNum;
  input BackendDAE.EqSystem syst;
  input BackendDAE.Shared shared;
  input Boolean skipDiscInAlgorithm;
  input Integer iuniqueEqIndex;
  input list<SimCodeVar.SimVar> itempvars;
  output list<SimCode.SimEqSystem> equation_;
  output Integer ouniqueEqIndex;
  output list<SimCodeVar.SimVar> otempvars;
algorithm
  (equation_, ouniqueEqIndex, otempvars) := matchcontinue (eqNum, varNum, syst, shared, skipDiscInAlgorithm, iuniqueEqIndex, itempvars)
    local
      DAE.ComponentRef cr;
      BackendDAE.VarKind kind;
      Option<DAE.VariableAttributes> values;
      BackendDAE.Var v;
      BackendDAE.Variables vars;
      BackendDAE.EquationArray eqns;
      BackendDAE.Equation eqn;
      Integer    uniqueEqIndex;
      list<DAE.Statement> algStatements;
      list<DAE.ComponentRef> conditions;
      list<SimCode.SimEqSystem> resEqs;
      list<BackendDAE.WhenClause> wcl;
      DAE.ComponentRef left, varOutput;
      DAE.Exp e1, e2, varexp, exp_, right, cond, prevarexp;
      BackendDAE.WhenEquation whenEquation, elseWhen;
      String algStr, message, eqStr;
      DAE.ElementSource source;
      list<DAE.Statement> asserts;
      SimCode.SimEqSystem elseWhenEquation;
      DAE.Algorithm alg;
      list<SimCodeVar.SimVar> tempvars;
      Boolean initialCall;
      DAE.Expand crefExpand;
      Boolean homotopySupport;
      DAE.FunctionTree funcs;

    /*
    // solve always a linear equations
    case (_, _, BackendDAE.EQSYSTEM(orderedVars=vars, orderedEqs=eqns), _, _, _, _)
      equation
        BackendDAE.EQUATION(exp=e1, scalar=e2, source=source) = BackendEquation.equationNth1(eqns, eqNum);
        (v as BackendDAE.VAR(varName = cr)) = BackendVariable.getVarAt(vars, varNum);
        varexp = Expression.crefExp(cr);
        varexp = bcallret1(BackendVariable.isStateVar(v), Expression.expDer, varexp, varexp);
        (exp_, asserts) = ExpressionSolve.solveLin(e1, e2, varexp);
        source = DAEUtil.addSymbolicTransformationSolve(true, source, cr, e1, e2, exp_, asserts);
        (resEqs, uniqueEqIndex) = addAssertEqn(asserts, {SimCode.SES_SIMPLE_ASSIGN(iuniqueEqIndex, cr, exp_, source)}, iuniqueEqIndex+1);
      then
        (resEqs, uniqueEqIndex, itempvars);
    */
    // solved equation
    case (_, _, BackendDAE.EQSYSTEM(orderedVars=vars, orderedEqs=eqns), _, _, _, _)
      equation
        BackendDAE.SOLVED_EQUATION(exp=e2, source=source) = BackendEquation.equationNth1(eqns, eqNum);
        (v as BackendDAE.VAR(varName = cr)) = BackendVariable.getVarAt(vars, varNum);
        varexp = Expression.crefExp(cr);
        varexp = if BackendVariable.isStateVar(v) then Expression.expDer(varexp) else varexp;
      then
        ({SimCode.SES_SIMPLE_ASSIGN(iuniqueEqIndex, cr, e2, source)}, iuniqueEqIndex+1, itempvars);

    // when eq without else
    case (_, _,  BackendDAE.EQSYSTEM(orderedEqs=eqns), BackendDAE.SHARED(), _, _, _)
      equation
        BackendDAE.WHEN_EQUATION(whenEquation=whenEquation, source=source) = BackendEquation.equationNth1(eqns, eqNum);
        BackendDAE.WHEN_EQ(cond, left, right, NONE()) = whenEquation;
        (conditions, initialCall) = BackendDAEUtil.getConditionList(cond);
      then
        ({SimCode.SES_WHEN(iuniqueEqIndex, conditions, initialCall, left, right, NONE(), source)}, iuniqueEqIndex+1, itempvars);

    // when eq with else
    case (_, _, BackendDAE.EQSYSTEM(orderedEqs=eqns), BackendDAE.SHARED(eventInfo=BackendDAE.EVENT_INFO(whenClauseLst=wcl)), _, _, _)
      equation
        BackendDAE.WHEN_EQUATION(whenEquation=whenEquation, source=source) = BackendEquation.equationNth1(eqns, eqNum);
        BackendDAE.WHEN_EQ(cond, left, right, SOME(elseWhen)) = whenEquation;
        elseWhenEquation = createElseWhenEquation(elseWhen, wcl, source);
        (conditions, initialCall) = BackendDAEUtil.getConditionList(cond);
      then
        ({SimCode.SES_WHEN(iuniqueEqIndex, conditions, initialCall, left, right, SOME(elseWhenEquation), source)}, iuniqueEqIndex+1, itempvars);

    // single equation
    case (_, _, BackendDAE.EQSYSTEM(orderedVars=vars, orderedEqs=eqns), _, _, _, _)
      equation
        BackendDAE.EQUATION(exp=e1, scalar=e2, source=source) = BackendEquation.equationNth1(eqns, eqNum);
        (v as BackendDAE.VAR(varName = cr)) = BackendVariable.getVarAt(vars, varNum);
        varexp = Expression.crefExp(cr);
        varexp = if BackendVariable.isStateVar(v) then Expression.expDer(varexp) else varexp;
        BackendDAE.SHARED(functionTree = funcs) = shared; 
        (exp_, asserts) = ExpressionSolve.solve2(e1, e2, varexp, SOME(funcs));
        cr = if BackendVariable.isStateVar(v) then ComponentReference.crefPrefixDer(cr) else cr;
        source = DAEUtil.addSymbolicTransformationSolve(true, source, cr, e1, e2, exp_, asserts);
        (resEqs, uniqueEqIndex) = addAssertEqn(asserts, {SimCode.SES_SIMPLE_ASSIGN(iuniqueEqIndex, cr, exp_, source)}, iuniqueEqIndex+1);
      then
        (resEqs, uniqueEqIndex, itempvars);

    // single equation from if-equation -> 0.0 = if .. then bla else lbu and var is not in all branches
    // change branches without variable to var - pre(var)
    case (_, _, BackendDAE.EQSYSTEM(orderedVars=vars, orderedEqs=eqns), _, _, _, _)
      equation
        BackendDAE.EQUATION(exp=e1 as DAE.RCONST(_), scalar=e2 as DAE.IFEXP(), source=source) = BackendEquation.equationNth1(eqns, eqNum);
        (v as BackendDAE.VAR(varName = cr)) = BackendVariable.getVarAt(vars, varNum);
        varexp = Expression.crefExp(cr);
        varexp = if BackendVariable.isStateVar(v) then Expression.expDer(varexp) else varexp;
        failure((_, _) = ExpressionSolve.solve(e1, e2, varexp));
        prevarexp = Expression.makePureBuiltinCall("pre", {varexp}, Expression.typeof(varexp));
        prevarexp = Expression.expSub(varexp, prevarexp);
        (e2, _) = Expression.traverseExp(e2, replaceIFBrancheswithoutVar, (varexp, prevarexp));
        eqn = BackendDAE.EQUATION(e1, e2, source, BackendDAE.EQ_ATTR_DEFAULT_UNKNOWN);
        (resEqs, uniqueEqIndex, tempvars) = createNonlinearResidualEquations({eqn}, iuniqueEqIndex, itempvars);
        cr = if BackendVariable.isStateVar(v) then ComponentReference.crefPrefixDer(cr) else cr;
        (_, homotopySupport) = BackendDAETransform.traverseExpsOfEquation(eqn, containsHomotopyCall, false);
      then
        ({SimCode.SES_NONLINEAR(uniqueEqIndex, resEqs, {cr}, 0, NONE(), false, homotopySupport, false)}, uniqueEqIndex+1, tempvars);

    // non-linear
    case (_, _, BackendDAE.EQSYSTEM(orderedVars=vars, orderedEqs=eqns), _, _, _, _)
      equation
        (eqn as BackendDAE.EQUATION(exp=e1, scalar=e2)) = BackendEquation.equationNth1(eqns, eqNum);
        (v as BackendDAE.VAR(varName = cr)) = BackendVariable.getVarAt(vars, varNum);
        varexp = Expression.crefExp(cr);
        varexp = if BackendVariable.isStateVar(v) then Expression.expDer(varexp) else varexp;
        failure((_, _) = ExpressionSolve.solve(e1, e2, varexp));
        // index = System.tmpTick();
        (resEqs, uniqueEqIndex, tempvars) = createNonlinearResidualEquations({eqn}, iuniqueEqIndex, itempvars);
        cr = if BackendVariable.isStateVar(v) then ComponentReference.crefPrefixDer(cr) else cr;
        (_, homotopySupport) = BackendDAETransform.traverseExpsOfEquation(eqn, containsHomotopyCall, false);
      then
        ({SimCode.SES_NONLINEAR(uniqueEqIndex, resEqs, {cr}, 0, NONE(), false, homotopySupport, false)}, uniqueEqIndex+1, tempvars);

    // Algorithm for single variable.
    case (_, _, BackendDAE.EQSYSTEM(orderedVars=vars, orderedEqs=eqns), _, true, _, _)
      equation
        BackendDAE.ALGORITHM(alg=alg, source=source, expand=crefExpand)  = BackendEquation.equationNth1(eqns, eqNum);
        varOutput::{} = CheckModel.checkAndGetAlgorithmOutputs(alg, source, crefExpand);
        v = BackendVariable.getVarAt(vars, varNum);
        // The output variable of the algorithm must be the variable solved
        // for, otherwise we need to solve an inverse problem of an algorithm
        // section.
        true = ComponentReference.crefEqualNoStringCompare(BackendVariable.varCref(v), varOutput);
        DAE.ALGORITHM_STMTS(algStatements) = BackendDAEUtil.collateAlgorithm(alg, NONE());
        algStatements = BackendDAEUtil.removeDiscreteAssignments(algStatements, vars);
      then
        ({SimCode.SES_ALGORITHM(iuniqueEqIndex, algStatements)}, iuniqueEqIndex+1, itempvars);

    // algorithm for single variable
    case (_, _, BackendDAE.EQSYSTEM(orderedVars=vars, orderedEqs=eqns), _,false, _, _)
      equation
        BackendDAE.ALGORITHM(alg=alg, source=source, expand=crefExpand) = BackendEquation.equationNth1(eqns, eqNum);
        varOutput::{} = CheckModel.checkAndGetAlgorithmOutputs(alg, source, crefExpand);
        v = BackendVariable.getVarAt(vars, varNum);
        // The output variable of the algorithm must be the variable solved
        // for, otherwise we need to solve an inverse problem of an algorithm
        // section.
        true = ComponentReference.crefEqualNoStringCompare(BackendVariable.varCref(v), varOutput);
        DAE.ALGORITHM_STMTS(algStatements) = BackendDAEUtil.collateAlgorithm(alg, NONE());
      then
        ({SimCode.SES_ALGORITHM(iuniqueEqIndex, algStatements)}, iuniqueEqIndex+1, itempvars);

    // inverse Algorithm for single variable
    case (_, _, BackendDAE.EQSYSTEM(orderedVars = vars, orderedEqs = eqns), _, _, _, _)
      equation
        BackendDAE.ALGORITHM(alg=alg, source=source, expand=crefExpand) = BackendEquation.equationNth1(eqns, eqNum);
        varOutput::{} = CheckModel.checkAndGetAlgorithmOutputs(alg, source, crefExpand);
        v = BackendVariable.getVarAt(vars, varNum);
        // We need to solve an inverse problem of an algorithm section.
        false = ComponentReference.crefEqualNoStringCompare(BackendVariable.varCref(v), varOutput);
        DAE.ALGORITHM_STMTS(algStatements) = BackendDAEUtil.collateAlgorithm(alg, NONE());
        algStatements = solveAlgorithmInverse(algStatements, {v});
      then
        ({SimCode.SES_ALGORITHM(iuniqueEqIndex, algStatements)}, iuniqueEqIndex+1, itempvars);

    // inverse Algorithm for single variable failed
    case (_, _, BackendDAE.EQSYSTEM(orderedVars = vars, orderedEqs = eqns), _, _, _, _)
      equation
        BackendDAE.ALGORITHM(alg=alg, source=source, expand=crefExpand) = BackendEquation.equationNth1(eqns, eqNum);
        varOutput::{} = CheckModel.checkAndGetAlgorithmOutputs(alg, source, crefExpand);
        v = BackendVariable.getVarAt(vars, varNum);
        // We need to solve an inverse problem of an algorithm section.
        false = ComponentReference.crefEqualNoStringCompare(BackendVariable.varCref(v), varOutput);
        algStr =  DAEDump.dumpAlgorithmsStr({DAE.ALGORITHM(alg, source)});
        message = ComponentReference.printComponentRefStr(BackendVariable.varCref(v));
        message = stringAppendList({"Inverse Algorithm needs to be solved for ", message, " in \n", algStr, "This has not been implemented yet.\n"});
        Error.addMessage(Error.INTERNAL_ERROR, {message});
      then fail();
  end matchcontinue;
end createEquation;

protected function replaceIFBrancheswithoutVar
  input DAE.Exp inExp;
  input tuple<DAE.Exp, DAE.Exp> inTpl;
  output DAE.Exp outExp;
  output tuple<DAE.Exp, DAE.Exp> outTpl;
algorithm
  (outExp,outTpl) := match (inExp,inTpl)
    local
      DAE.Exp exp, crexp, cond, e1, e2;
      Boolean b;
    case (DAE.IFEXP(cond, e1, e2), (crexp, exp))
      equation
        b = Expression.expContains(e1, crexp);
        e1 = if b then e1 else exp;
        b = Expression.expContains(e2, crexp);
        e2 = if b then e2 else exp;
      then (DAE.IFEXP(cond, e1, e2), inTpl);
    else (inExp,inTpl);
  end match;
end replaceIFBrancheswithoutVar;

protected function solveAlgorithmInverse "author: jfrenkel
  This function solves symbolically a algorithm inverse for a few special cases."
  input list<DAE.Statement> inStmts;
  input list<BackendDAE.Var> inSolveFor;
  output list<DAE.Statement> outStmts;
algorithm
  outStmts := match (inStmts, inSolveFor)
    local
      DAE.ComponentRef cr1;
      DAE.Exp e11, e12, varexp1, solvedExp1;
      DAE.ElementSource source1;
      DAE.Type tp1;
      BackendDAE.Var v1;

      DAE.ComponentRef cr2;
      DAE.Exp e21, e22, varexp2, solvedExp2;
      DAE.ElementSource source2;
      DAE.Type tp2;
      BackendDAE.Var v2;

      list<DAE.Statement> asserts;

    // Algorithm for single variable
    // a := exp1(b); => b := exp1_(a);
    case (DAE.STMT_ASSIGN(exp1=e11, exp=e12, source=source1)::{}, (v1 as BackendDAE.VAR(varName=cr1))::{}) equation
      varexp1 = Expression.crefExp(cr1);
      varexp1 = if BackendVariable.isStateVar(v1) then Expression.expDer(varexp1) else varexp1;
      (solvedExp1, asserts) = ExpressionSolve.solve(e11, e12, varexp1);
      cr1 = if BackendVariable.isStateVar(v1) then ComponentReference.crefPrefixDer(cr1) else cr1;
      source1 = DAEUtil.addSymbolicTransformationSolve(true, source1, cr1, e11, e12, solvedExp1, asserts);
      tp1 = Expression.typeof(varexp1);
    then {DAE.STMT_ASSIGN(tp1, varexp1, solvedExp1, source1)};

    // a := exp1(b); c := exp2(d); => b := exp1_(a); d := exp2_(c);
    case (DAE.STMT_ASSIGN(exp1=e11, exp=e12, source=source1)::DAE.STMT_ASSIGN(exp1=e21, exp=e22, source=source2)::{}, (v1 as BackendDAE.VAR(varName=cr1))::(v2 as BackendDAE.VAR(varName=cr2))::{}) equation
      // check for cross-over dependencies
      false = Expression.expHasCref(e12, cr2);
      false = Expression.expHasCref(e22, cr1);

      varexp1 = Expression.crefExp(cr1);
      varexp1 = if BackendVariable.isStateVar(v1) then Expression.expDer(varexp1) else varexp1;
      (solvedExp1, asserts) = ExpressionSolve.solve(e11, e12, varexp1);
      cr1 = if BackendVariable.isStateVar(v1) then ComponentReference.crefPrefixDer(cr1) else cr1;
      source1 = DAEUtil.addSymbolicTransformationSolve(true, source1, cr1, e11, e12, solvedExp1, asserts);
      tp1 = Expression.typeof(varexp1);

      varexp2 = Expression.crefExp(cr2);
      varexp2 = if BackendVariable.isStateVar(v2) then Expression.expDer(varexp2) else varexp2;
      (solvedExp2, asserts) = ExpressionSolve.solve(e21, e22, varexp2);
      cr2 = if BackendVariable.isStateVar(v2) then ComponentReference.crefPrefixDer(cr2) else cr2;
      source2 = DAEUtil.addSymbolicTransformationSolve(true, source2, cr2, e21, e22, solvedExp2, asserts);
      tp2 = Expression.typeof(varexp2);
    then {DAE.STMT_ASSIGN(tp1, varexp1, solvedExp1, source1), DAE.STMT_ASSIGN(tp2, varexp2, solvedExp2, source2)};
  end match;
end solveAlgorithmInverse;

// =============================================================================
// section for creating SimCode when-clauses
//
// =============================================================================

protected function createSimWhenClauses
  input BackendDAE.BackendDAE inBackendDAE;
  output list<SimCode.SimWhenClause> outSimWhenClause;
algorithm
  outSimWhenClause := matchcontinue (inBackendDAE)
    local
      list<BackendDAE.WhenClause> wc;
      BackendDAE.EqSystems systs;
      list<SimCode.SimWhenClause> simWhenClauses;

    case (BackendDAE.DAE(eqs=systs, shared=BackendDAE.SHARED(eventInfo=BackendDAE.EVENT_INFO(whenClauseLst=wc)))) equation
      simWhenClauses = List.fold(systs, createSimWhenClausesEqs, {});
      simWhenClauses =  List.fold(wc, whenClauseToSimWhenClause, simWhenClauses);
    then listReverse(simWhenClauses);

    else equation
      Error.addMessage(Error.INTERNAL_ERROR, {"function createSimWhenClauses failed"});
    then fail();
  end matchcontinue;
end createSimWhenClauses;

protected function createSimWhenClausesEqs
  input BackendDAE.EqSystem inEqSystem;
  input list<SimCode.SimWhenClause> inSimWhenClause;
  output list<SimCode.SimWhenClause> outSimWhenClause;
protected
  BackendDAE.EquationArray eqs;
algorithm
  BackendDAE.EQSYSTEM(orderedEqs=eqs) := inEqSystem;
  outSimWhenClause := BackendEquation.traverseEquationArray(eqs, findWhenEquation, inSimWhenClause);
end createSimWhenClausesEqs;

protected function findWhenEquation
  input BackendDAE.Equation inEq;
  input list<SimCode.SimWhenClause> inWhen;
  output BackendDAE.Equation outEq;
  output list<SimCode.SimWhenClause> outWhen;
algorithm
  (outEq,outWhen) := matchcontinue (inEq,inWhen)
    local
      BackendDAE.WhenEquation eq;
      BackendDAE.Equation eqn;
      list<SimCode.SimWhenClause> simWhenClause;

    case (eqn as BackendDAE.WHEN_EQUATION(whenEquation = eq), simWhenClause) equation
      simWhenClause = findWhenEquation1(eq, simWhenClause);
    then (eqn, simWhenClause);

    else (inEq,inWhen);
  end matchcontinue;
end findWhenEquation;

protected function findWhenEquation1
  input BackendDAE.WhenEquation inWhenEquation;
  input list<SimCode.SimWhenClause> inSimWhenClause;
  output list<SimCode.SimWhenClause> outSimWhenClause;
algorithm
  outSimWhenClause := match(inWhenEquation, inSimWhenClause)
    local
      DAE.Exp cond;
      list<DAE.ComponentRef> conditions;
      list<DAE.ComponentRef> conditionVars;
      BackendDAE.WhenEquation we;
      Boolean initialCall;

    case (BackendDAE.WHEN_EQ(condition=cond, elsewhenPart=NONE()), _) equation
      (conditions, initialCall) = BackendDAEUtil.getConditionList(cond);
      conditionVars = Expression.extractCrefsFromExp(cond);
    then SimCode.SIM_WHEN_CLAUSE(conditionVars, conditions, initialCall, {}, SOME(inWhenEquation))::inSimWhenClause;

    case (BackendDAE.WHEN_EQ(condition=cond, elsewhenPart=SOME(we)), _) equation
      (conditions, initialCall) = BackendDAEUtil.getConditionList(cond);
      conditionVars = Expression.extractCrefsFromExp(cond);
    then findWhenEquation1(we, SimCode.SIM_WHEN_CLAUSE(conditionVars, conditions, initialCall, {}, SOME(inWhenEquation))::inSimWhenClause);
  end match;
end findWhenEquation1;

protected function whenClauseToSimWhenClause
  input BackendDAE.WhenClause inWhenClause;
  input list<SimCode.SimWhenClause> inSimWhenClauseList;
  output list<SimCode.SimWhenClause> outSimWhenClauseList;
protected
  DAE.Exp condition;
  list<BackendDAE.WhenOperator> reinitStmtLst;
  list<DAE.ComponentRef> conditionVars;
  list<DAE.ComponentRef> conditions;
  Boolean initialCall;
algorithm
  BackendDAE.WHEN_CLAUSE(condition=condition, reinitStmtLst=reinitStmtLst) := inWhenClause;

  (conditions, initialCall) := BackendDAEUtil.getConditionList(condition);
  conditionVars := Expression.extractCrefsFromExp(condition);

  outSimWhenClauseList := SimCode.SIM_WHEN_CLAUSE(conditionVars, conditions, initialCall, reinitStmtLst, NONE())::inSimWhenClauseList;
end whenClauseToSimWhenClause;

// =============================================================================
// section for ???
//
// =============================================================================

protected function createNonlinearResidualEquationsComplex
  input DAE.Exp inExp;
  input DAE.Exp inExp1;
  input DAE.ElementSource source;
  input Integer iuniqueEqIndex;
  input list<SimCodeVar.SimVar> itempvars;
  output list<SimCode.SimEqSystem> equations_;
  output Integer ouniqueEqIndex;
  output list<SimCodeVar.SimVar> otempvars;
algorithm
  (equations_, ouniqueEqIndex, otempvars) := matchcontinue (inExp, inExp1)
    local
      DAE.ComponentRef cr, crtmp;
      list<DAE.ComponentRef> crlst;
      list<list<DAE.ComponentRef>> crlstlst;
      DAE.Exp e1, e2, e1_1, e2_1, etmp;
      DAE.Statement stms;
      DAE.Type tp;
      list<DAE.Type> tplst;
      list<DAE.Exp> expl, crexplst;
      list<DAE.Var> varLst;
      list<DAE.Exp> e1lst, e2lst;
      SimCode.SimEqSystem simeqn;
      list<SimCode.SimEqSystem> eqSystlst;
      list<tuple<DAE.Exp, DAE.Exp>> exptl;
      Integer uniqueEqIndex;
      Absyn.Path path, rpath;
      String ident, s, s1, s2;
      list<SimCodeVar.SimVar> tempvars;

    /* casts */
    case (DAE.CAST(_, e1), _) equation
      (equations_, ouniqueEqIndex, otempvars) = createNonlinearResidualEquationsComplex(e1, inExp1, source, iuniqueEqIndex, itempvars);
    then (equations_, ouniqueEqIndex, otempvars);

    /* casts */
    case (_, DAE.CAST(_, e2)) equation
      (equations_, ouniqueEqIndex, otempvars) = createNonlinearResidualEquationsComplex(inExp, e2, source, iuniqueEqIndex, itempvars);
    then (equations_, ouniqueEqIndex, otempvars);

    /* a = f() */
    case (DAE.CREF(componentRef=cr), _) equation
      // ((e1_1, _)) = Expression.extendArrExp((inExp, false));
      (e2_1, _) = Expression.extendArrExp(inExp1, false);
      // true = ComponentReference.crefEqualNoStringCompare(cr, cr2);
      (tp as DAE.T_COMPLEX(varLst=varLst, complexClassType=ClassInf.RECORD(path)))  = Expression.typeof(inExp);
      // tmp
      ident = Absyn.pathStringUnquoteReplaceDot(path, "_");
      crtmp = ComponentReference.makeCrefIdent("$TMP_" + ident + intString(iuniqueEqIndex), tp, {});
      tempvars = createTempVars(varLst, crtmp, itempvars);
      // 0 = a - tmp
      e1lst = List.map1(varLst, Expression.generateCrefsExpFromExpVar, cr);
      e2lst = List.map1(varLst, Expression.generateCrefsExpFromExpVar, crtmp);
      exptl = List.threadTuple(e1lst, e2lst);
      (eqSystlst, uniqueEqIndex) = List.map1Fold(exptl, makeSES_RESIDUAL1, source, iuniqueEqIndex);
      // tmp = f(x, y)
      etmp = Expression.crefExp(crtmp);
      stms = DAE.STMT_ASSIGN(tp, etmp, e2_1, source);
      eqSystlst = SimCode.SES_ALGORITHM(uniqueEqIndex, {stms})::eqSystlst;
    then (eqSystlst, uniqueEqIndex+1, tempvars);

    /* f() = a */
    case (_, DAE.CREF(componentRef=cr)) equation
      // true = ComponentReference.crefEqualNoStringCompare(cr, cr2);
      (e1_1, _) = Expression.extendArrExp(inExp, false);
      // ((e2_1, _)) = Expression.extendArrExp((inExp1, false));
      (tp as DAE.T_COMPLEX(varLst=varLst, complexClassType=ClassInf.RECORD(path)))  = Expression.typeof(inExp1);
      // tmp
      ident = Absyn.pathStringUnquoteReplaceDot(path, "_");
      crtmp = ComponentReference.makeCrefIdent("$TMP_" + ident + intString(iuniqueEqIndex), tp, {});
      tempvars = createTempVars(varLst, crtmp, itempvars);
      // 0 = a - tmp
      e1lst = List.map1(varLst, Expression.generateCrefsExpFromExpVar, cr);
      e2lst = List.map1(varLst, Expression.generateCrefsExpFromExpVar, crtmp);
      exptl = List.threadTuple(e1lst, e2lst);
      (eqSystlst, uniqueEqIndex) = List.map1Fold(exptl, makeSES_RESIDUAL1, source, iuniqueEqIndex);
      // tmp = f(x, y)
      etmp = Expression.crefExp(crtmp);
      stms = DAE.STMT_ASSIGN(tp, etmp, e1_1, source);
      eqSystlst = SimCode.SES_ALGORITHM(uniqueEqIndex, {stms})::eqSystlst;
    then (eqSystlst, uniqueEqIndex+1, tempvars);

    /* Record() = f() */
    case (DAE.CALL(path=path, expLst=e2lst, attr=DAE.CALL_ATTR(ty= tp as DAE.T_COMPLEX(varLst=varLst, complexClassType=ClassInf.RECORD(rpath)))), _) equation
      true = Absyn.pathEqual(path, rpath);
      (e2_1, _) = Expression.extendArrExp(inExp1, false);
      // true = ComponentReference.crefEqualNoStringCompare(cr, cr2);
      // tmp = f()
      ident = Absyn.pathStringUnquoteReplaceDot(path, "_");
      cr = ComponentReference.makeCrefIdent("$TMP_" + ident + intString(iuniqueEqIndex), tp, {});
      e1_1 = Expression.crefExp(cr);
      stms = DAE.STMT_ASSIGN(tp, e1_1, e2_1, source);
      simeqn = SimCode.SES_ALGORITHM(iuniqueEqIndex, {stms});
      uniqueEqIndex = iuniqueEqIndex + 1;
      // Record()-tmp = 0
      e1lst = List.map1(varLst, Expression.generateCrefsExpFromExpVar, cr);
      exptl = List.threadTuple(e1lst, e2lst);
      (eqSystlst, uniqueEqIndex) = List.map1Fold(exptl, makeSES_RESIDUAL1, source, uniqueEqIndex);
      eqSystlst = simeqn::eqSystlst;
      tempvars = createTempVars(varLst, cr, itempvars);
    then (eqSystlst, uniqueEqIndex, tempvars);

    /* f() = Record() */
    case (_, DAE.CALL(path=path, expLst=e2lst, attr=DAE.CALL_ATTR(ty=tp as DAE.T_COMPLEX(varLst=varLst, complexClassType=ClassInf.RECORD(rpath))))) equation
      true = Absyn.pathEqual(path, rpath);
      (e1_1, _) = Expression.extendArrExp(inExp1, false);
      // true = ComponentReference.crefEqualNoStringCompare(cr, cr2);
      // tmp = f()
      ident = Absyn.pathStringUnquoteReplaceDot(path, "_");
      cr = ComponentReference.makeCrefIdent("$TMP_" + ident + intString(iuniqueEqIndex), tp, {});
      e2_1 = Expression.crefExp(cr);
      stms = DAE.STMT_ASSIGN(tp, e2_1, e1_1, source);
      simeqn = SimCode.SES_ALGORITHM(iuniqueEqIndex, {stms});
      uniqueEqIndex = iuniqueEqIndex + 1;
      // Record()-tmp = 0
      e1lst = List.map1(varLst, Expression.generateCrefsExpFromExpVar, cr);
      exptl = List.threadTuple(e1lst, e2lst);
      (eqSystlst, uniqueEqIndex) = List.map1Fold(exptl, makeSES_RESIDUAL1, source, uniqueEqIndex);
      eqSystlst = simeqn::eqSystlst;
      tempvars = createTempVars(varLst, cr, itempvars);
    then (eqSystlst, uniqueEqIndex, tempvars);

    /* Tuple() = f()  */
    case (DAE.TUPLE(PR=expl), DAE.CALL(path=path)) equation
      // true = ComponentReference.crefEqualNoStringCompare(cr, cr2);
      // tmp = f()
      tp = Expression.typeof(inExp);
      ident = Absyn.pathStringUnquoteReplaceDot(path, "_");
      cr = ComponentReference.makeCrefIdent("$TMP_" + ident + intString(iuniqueEqIndex), tp, {});
      crexplst = List.map1(expl, Expression.generateCrefsExpFromExp, cr);
      stms = DAE.STMT_TUPLE_ASSIGN(tp, crexplst, inExp1, source);
      simeqn = SimCode.SES_ALGORITHM(iuniqueEqIndex, {stms});
      uniqueEqIndex = iuniqueEqIndex + 1;

      // for creating makeSES_RESIDUAL1 all crefs needs to expanded
      // and all WILD() crefs are filtered
      expl = List.filterOnTrue(expl, Expression.isNotWild);
      expl = List.flatten(List.map1(expl, Expression.generateCrefsExpLstFromExp, NONE()));
      crexplst = List.flatten(List.map1(expl, Expression.generateCrefsExpLstFromExp, SOME(cr)));
      crlst = List.map(crexplst, Expression.expCref);
      crlstlst = List.map1(crlst, ComponentReference.expandCref, true);
      crlst = List.flatten(crlstlst);
      crexplst = List.map(crlst, Expression.crefExp);

      crlst = List.map(expl, Expression.expCref);
      crlstlst = List.map1(crlst, ComponentReference.expandCref, true);
      crlst = List.flatten(crlstlst);
      expl = List.map(crlst, Expression.crefExp);

      // Tuple() - tmp = 0
      exptl = List.threadTuple(expl, crexplst);
      (eqSystlst, uniqueEqIndex) = List.map1Fold(exptl, makeSES_RESIDUAL1, source, uniqueEqIndex);
      eqSystlst = simeqn::eqSystlst;

      tempvars = createTempVarsforCrefs(listReverse(crexplst), itempvars);
    then (eqSystlst, uniqueEqIndex, tempvars);

    // failure
    else equation
      s1 = ExpressionDump.printExpStr(inExp);
      s2 = ExpressionDump.printExpStr(inExp1);
      s = stringAppendList({"function createNonlinearResidualEquationsComplex failed for: ", s1, " = " , s2 });
      Error.addMessage(Error.INTERNAL_ERROR, {s});
    then fail();
  end matchcontinue;
end createNonlinearResidualEquationsComplex;

protected function createArrayTempVar
  input DAE.ComponentRef name;
  input list<Integer> dims;
  input list<DAE.Exp> inTmpCrefsLst;
  input list<SimCodeVar.SimVar> itempvars;
  output list<SimCodeVar.SimVar> otempvars;
algorithm
  otempvars := match(inTmpCrefsLst)
    local
      list<DAE.Exp> rest;
      list<SimCodeVar.SimVar> tempvars;
      DAE.Type ty;
      DAE.ComponentRef cr;
      SimCodeVar.SimVar var;
      list<String> slst;

    case({}) then itempvars;

    case(DAE.CREF(cr, ty)::rest) equation
      slst = List.map(dims, intString);
      var = SimCodeVar.SIMVAR(cr, BackendDAE.VARIABLE(), "", "", "", 0, NONE(), NONE(), NONE(), NONE(), false, ty, false, SOME(name), SimCodeVar.NOALIAS(), DAE.emptyElementSource, SimCodeVar.NONECAUS(), NONE(), slst, false, true);
      tempvars = createTempVarsforCrefs(rest, {var});
    then listAppend(listReverse(tempvars), itempvars);
  end match;
end createArrayTempVar;

protected function createTempVarsforCrefs
  input list<DAE.Exp> inTmpCrefsLst;
  input list<SimCodeVar.SimVar> itempvars;
  output list<SimCodeVar.SimVar> otempvars;
algorithm
  otempvars := match(inTmpCrefsLst)
    local
      list<DAE.Exp> rest, expl;
      DAE.Type ty;
      DAE.ComponentRef cr;
      SimCodeVar.SimVar var;
      Option<DAE.ComponentRef> arrayCref;
      list<SimCodeVar.SimVar> tempvars;
      list<String> numArrayElement;
      list<DAE.Dimension> inst_dims;

    case({}) then itempvars;

    case(DAE.ARRAY(array=expl)::rest) equation
      tempvars = createTempVarsforCrefs(expl, itempvars);
    then createTempVarsforCrefs(rest, tempvars);

    case(DAE.TUPLE(PR=expl)::rest) equation
      tempvars = createTempVarsforCrefs(expl, itempvars);
    then createTempVarsforCrefs(rest, tempvars);

    case(DAE.CREF(cr, ty)::rest) equation
      arrayCref = ComponentReference.getArrayCref(cr);
      inst_dims = ComponentReference.crefDims(cr);
      numArrayElement = List.map(inst_dims, ExpressionDump.dimensionString);
      var = SimCodeVar.SIMVAR(cr, BackendDAE.VARIABLE(), "", "", "", 0, NONE(), NONE(), NONE(), NONE(), false, ty, false, arrayCref, SimCodeVar.NOALIAS(), DAE.emptyElementSource, SimCodeVar.NONECAUS(), NONE(), numArrayElement, false, true);
    then createTempVarsforCrefs(rest, var::itempvars);
  end match;
end createTempVarsforCrefs;

protected function createTempVars
  input list<DAE.Var> varLst;
  input DAE.ComponentRef inCrefPrefix;
  input list<SimCodeVar.SimVar> itempvars;
  output list<SimCodeVar.SimVar> otempvars;
algorithm
  otempvars := match(varLst)
    local
      list<DAE.Var> rest, varlst;
      list<SimCodeVar.SimVar> tempvars;
      DAE.Ident name;
      DAE.Type ty;
      DAE.ComponentRef cr;
      SimCodeVar.SimVar var;

    case({})
    then itempvars;

    case(DAE.TYPES_VAR(name=name, ty=ty as DAE.T_COMPLEX(complexClassType=ClassInf.RECORD(_)))::rest) equation
      cr = ComponentReference.crefPrependIdent(inCrefPrefix, name, {}, ty);
      tempvars = createTempVars(rest, cr, itempvars);
    then createTempVars(rest, cr, tempvars);

    case(DAE.TYPES_VAR(name=name, ty=ty)::rest) equation
      cr = ComponentReference.crefPrependIdent(inCrefPrefix, name, {}, ty);
      var = SimCodeVar.SIMVAR(cr, BackendDAE.VARIABLE(), "", "", "", 0, NONE(), NONE(), NONE(), NONE(), false, ty, false, NONE(), SimCodeVar.NOALIAS(), DAE.emptyElementSource, SimCodeVar.NONECAUS(), NONE(), {}, false, true);
    then createTempVars(rest, inCrefPrefix, var::itempvars);
  end match;
end createTempVars;

protected function createNonlinearResidualEquations
  input list<BackendDAE.Equation> eqs;
  input Integer iuniqueEqIndex;
  input list<SimCodeVar.SimVar> itempvars;
  output list<SimCode.SimEqSystem> eqSystems;
  output Integer ouniqueEqIndex;
  output list<SimCodeVar.SimVar> otempvars;
algorithm
  (eqSystems, ouniqueEqIndex, otempvars) := matchcontinue (eqs)
    local
      Integer size, uniqueEqIndex;
      DAE.Exp res_exp, e1, e2, e;
      list<DAE.Exp> explst, explst1;
      list<BackendDAE.Equation> rest;
      BackendDAE.Equation eq;
      list<SimCode.SimEqSystem> eqSystemsRest, eqSystlst;
      list<Integer> ds;
      DAE.ComponentRef left;
      list<DAE.Statement> algStatements;
      DAE.ElementSource source;
      list<tuple<DAE.Exp, DAE.Exp>> exptl;
      list<DAE.ComponentRef> crefs, crefstmp;
      list<SimCodeVar.SimVar> tempvars;
      BackendVarTransform.VariableReplacements repl;
      DAE.Type ty;
      String errorMessage;
      DAE.Expand crefExpand;

    case ({})
    then ({}, iuniqueEqIndex, itempvars);

    case (BackendDAE.EQUATION(exp=e1, scalar=e2, source=source)::rest) equation
      res_exp = Expression.createResidualExp(e1, e2);
      res_exp = Expression.replaceDerOpInExp(res_exp);
      (eqSystemsRest, uniqueEqIndex, tempvars) = createNonlinearResidualEquations(rest, iuniqueEqIndex, itempvars);
    then (SimCode.SES_RESIDUAL(uniqueEqIndex, res_exp, source)::eqSystemsRest, uniqueEqIndex+1, tempvars);

    case (BackendDAE.RESIDUAL_EQUATION(exp=e, source=source)::rest) equation
      (res_exp, _) = ExpressionSimplify.simplify(e);
      res_exp = Expression.replaceDerOpInExp(res_exp);
      (eqSystemsRest, uniqueEqIndex, tempvars) = createNonlinearResidualEquations(rest, iuniqueEqIndex, itempvars);
    then (SimCode.SES_RESIDUAL(uniqueEqIndex, res_exp, source) :: eqSystemsRest, uniqueEqIndex+1, tempvars);

    // An array equation
    case (BackendDAE.ARRAY_EQUATION(dimSize=ds, left=e1, right=e2, source=source)::rest) equation
      ty = Expression.typeof(e1);
      left = ComponentReference.makeCrefIdent("$TMP_" + intString(iuniqueEqIndex), ty, {});
      res_exp = Expression.createResidualExp(e1, e2);
      res_exp = Expression.replaceDerOpInExp(res_exp);
      crefstmp = ComponentReference.expandCref(left, false);
      explst1 = List.map(crefstmp, Expression.crefExp);
      (eqSystlst, uniqueEqIndex) = List.map1Fold(explst1, makeSES_RESIDUAL, source, iuniqueEqIndex);
      eqSystlst = SimCode.SES_ARRAY_CALL_ASSIGN(uniqueEqIndex, left, res_exp, source)::eqSystlst;
      tempvars = createArrayTempVar(left, ds, explst1, itempvars);
      (eqSystemsRest, uniqueEqIndex, tempvars) = createNonlinearResidualEquations(rest, uniqueEqIndex+1, tempvars);
      eqSystemsRest = listAppend(eqSystlst, eqSystemsRest);
    then (eqSystemsRest, uniqueEqIndex, tempvars);

    // An complex equation
    case (BackendDAE.COMPLEX_EQUATION(left=e1, right=e2, source=source)::rest) equation
      (e1, _) = ExpressionSimplify.simplify(e1);
      e1 = Expression.replaceDerOpInExp(e1);
      (e2, _) = ExpressionSimplify.simplify(e2);
      e2 = Expression.replaceDerOpInExp(e2);
      (eqSystlst, uniqueEqIndex, tempvars) = createNonlinearResidualEquationsComplex(e1, e2, source, iuniqueEqIndex, itempvars);
      (eqSystemsRest, uniqueEqIndex, tempvars) = createNonlinearResidualEquations(rest, uniqueEqIndex, tempvars);
      eqSystemsRest = listAppend(eqSystlst, eqSystemsRest);
    then (eqSystemsRest, uniqueEqIndex, tempvars);

    case ((eq as BackendDAE.WHEN_EQUATION(whenEquation=BackendDAE.WHEN_EQ()))::_) equation
      // This following does not work. It does not take index or elseWhen into account.
      // The generated code for the when-equation also does not solve a linear system; it uses the variables directly.
      /*
       tp = Expression.typeof(e2);
       e1 = Expression.makeCrefExp(left, tp);
       res_exp = DAE.BINARY(e1, DAE.SUB(tp), e2);
       res_exp = ExpressionSimplify.simplify(res_exp);
       res_exp = Expression.replaceDerOpInExp(res_exp);
       (eqSystemsRest) = createNonlinearResidualEquations(rest, repl, uniqueEqIndex );
       then
       (SimCode.SES_RESIDUAL(0, res_exp) :: eqSystemsRest, entrylst1);
       */
      Error.addSourceMessage(Error.UNSUPPORTED_LANGUAGE_FEATURE, {"non-linear equations within when-equations", "Perform non-linear operations outside the when-equation (this is slower, but works)"}, BackendEquation.equationInfo(eq));
    then fail();

    case (BackendDAE.ALGORITHM(alg=DAE.ALGORITHM_STMTS(algStatements), source=source, expand=crefExpand)::rest) equation
      crefs = CheckModel.checkAndGetAlgorithmOutputs(DAE.ALGORITHM_STMTS(algStatements), source, crefExpand);
      // BackendDump.debugStrCrefLstStr(("Crefs : ", crefs, ", ", "\n"));
      (crefstmp, repl) = createTmpCrefs(crefs, iuniqueEqIndex, {}, BackendVarTransform.emptyReplacements());
      // BackendDump.debugStrCrefLstStr(("Crefs : ", crefstmp, ", ", "\n"));
      explst = List.map(crefs, Expression.crefExp);
      explst = List.map(explst, Expression.replaceDerOpInExp);

      // BackendDump.dumpAlgorithms({DAE.ALGORITHM_STMTS(algStatements)}, 0);
      (algStatements, _) = BackendVarTransform.replaceStatementLst(algStatements, repl, SOME(BackendVarTransform.skipPreOperator), {}, false);
      // BackendDump.dumpAlgorithms({DAE.ALGORITHM_STMTS(algStatements)}, 0);

      explst1 = List.map(crefstmp, Expression.crefExp);
      explst1 = List.map(explst1, Expression.replaceDerOpInExp);
      tempvars = createTempVarsforCrefs(explst1, itempvars);

      // 0 = a - tmp
      exptl = List.threadTuple(explst, explst1);
      (eqSystlst, uniqueEqIndex) = List.map1Fold(exptl, makeSES_RESIDUAL1, source, iuniqueEqIndex);

      eqSystlst = SimCode.SES_ALGORITHM(uniqueEqIndex, algStatements)::eqSystlst;
      // Tpl.tplPrint(SimCodeDump.dumpEqs, eqSystlst);

      (eqSystemsRest, uniqueEqIndex, tempvars) = createNonlinearResidualEquations(rest, uniqueEqIndex+1, tempvars);
      eqSystemsRest = listAppend(eqSystlst, eqSystemsRest);
    then (eqSystemsRest, uniqueEqIndex, tempvars);

    case (eq::_) equation
      errorMessage = "function createNonlinearResidualEquations failed for equation: " + BackendDump.equationString(eq);
      Error.addSourceMessage(Error.INTERNAL_ERROR, {errorMessage}, BackendEquation.equationInfo(eq));
    then fail();
  end matchcontinue;
end createNonlinearResidualEquations;

public function dimsToAllIndexes
  input DAE.Dimensions inDims;
  output list<list<Integer>> outIndexes;
protected
  list<Integer> ilst;
  list<list<Integer>> lstlst;
algorithm
  ilst := Expression.dimensionsSizes(inDims);
  lstlst := List.map(ilst, List.intRange);
  outIndexes := dimsToAllIndexes1(lstlst);
end dimsToAllIndexes;

protected function dimsToAllIndexes1
  input list<list<Integer>> inDims;
  output list<list<Integer>> oAllIndex;
algorithm
  oAllIndex := match(inDims)
    local
      list<Integer> dims;
      list<list<Integer>> rest, indxes;
    case (dims::{})
      equation
        indxes = List.map(dims, List.create);
      then
        indxes;
    case (dims::rest)
      equation
        indxes = dimsToAllIndexes1(rest);
        // cons for each element in dims
        indxes = List.fold1(dims, dimsToAllIndexes2, indxes, {});
      then
        indxes;
  end match;
end dimsToAllIndexes1;

protected function dimsToAllIndexes2
  input Integer i;
  input list<list<Integer>> iIndex;
  input list<list<Integer>> iAllIndex;
  output list<list<Integer>> oAllIndex;
algorithm
  oAllIndex := List.map1(iIndex, List.consr, i);
  oAllIndex := listAppend(iAllIndex, oAllIndex);
end dimsToAllIndexes2;

protected function createTmpCrefs
  input list<DAE.ComponentRef> inCrefs;
  input Integer iuniqueEqIndex;
  input list<DAE.ComponentRef> inCrefsAcc;
  input BackendVarTransform.VariableReplacements iRepl;
  output list<DAE.ComponentRef> outCrefs;
  output BackendVarTransform.VariableReplacements oRepl;
algorithm
  (outCrefs, oRepl) := match(inCrefs)
    local
      DAE.ComponentRef cref, crtmp;
      list<DAE.ComponentRef> rest, result;
      DAE.Type tp;
      String ident;
      BackendVarTransform.VariableReplacements repl;

    case({})
    then (listReverse(inCrefsAcc), iRepl);

    case(cref::rest) equation
      ident = ComponentReference.printComponentRefStr(cref);
      ident = System.unquoteIdentifier(ident);
      ident = System.stringReplace(ident, ".", "$P");
      ident = System.stringReplace(ident, ",", "$c");
      ident = System.stringReplace(ident, "[", "$rB");
      ident = System.stringReplace(ident, "]", "$lB");
      tp = Types.arrayElementType(ComponentReference.crefLastType(cref));
      crtmp = ComponentReference.makeCrefIdent("$TMP_" + ident + "_" + intString(iuniqueEqIndex), tp, {});
      repl = BackendVarTransform.addReplacement(iRepl, cref, DAE.CREF(crtmp, tp), SOME(BackendVarTransform.skipPreOperator));
      (result, repl) = createTmpCrefs(rest, iuniqueEqIndex, crtmp::inCrefsAcc, repl);
    then (result, repl);
  end match;
end createTmpCrefs;

protected function makeSES_RESIDUAL
  input DAE.Exp inExp;
  input DAE.ElementSource source;
  input Integer uniqueEqIndex;
  output SimCode.SimEqSystem outSimEqn;
  output Integer ouniqueEqIndex;
  annotation(__OpenModelica_EarlyInline = true);
algorithm
  outSimEqn := SimCode.SES_RESIDUAL(uniqueEqIndex, inExp, source);
  ouniqueEqIndex := uniqueEqIndex+1;
end makeSES_RESIDUAL;

protected function makeSES_RESIDUAL1
  input tuple<DAE.Exp, DAE.Exp> inTpl;
  input DAE.ElementSource source;
  input Integer uniqueEqIndex;
  output SimCode.SimEqSystem outSimEqn;
  output Integer ouniqueEqIndex;
protected
  DAE.Exp e1, e2, e;
algorithm
  (e1, e2) := inTpl;
  e := Expression.createResidualExp(e1, e2);
  outSimEqn := SimCode.SES_RESIDUAL(uniqueEqIndex, e, source);
  ouniqueEqIndex := uniqueEqIndex +1;
end makeSES_RESIDUAL1;

protected function makeSES_SIMPLE_ASSIGN
  input tuple<DAE.Exp, DAE.Exp> inTpl;
  input DAE.ElementSource source;
  input Integer iuniqueEqIndex;
  output SimCode.SimEqSystem outSimEqn;
  output Integer ouniqueEqIndex;
protected
  DAE.Exp e;
  DAE.ComponentRef cr;
algorithm
  (DAE.CREF(cr, _), e) := inTpl;
  outSimEqn := SimCode.SES_SIMPLE_ASSIGN(iuniqueEqIndex, cr, e, source);
  ouniqueEqIndex := iuniqueEqIndex+1;
end makeSES_SIMPLE_ASSIGN;

protected function createOdeSystem
  input Boolean genDiscrete "if true generate discrete equations";
  input Boolean skipDiscInAlgorithm "if true skip discrete algorithm vars";
  input BackendDAE.EqSystem isyst;
  input BackendDAE.Shared ishared;
  input BackendDAE.StrongComponent inComp;
  input Integer iuniqueEqIndex;
  input list<SimCodeVar.SimVar> itempvars;
  input Integer isccIndex; //just to create the simEq to scc mapping. If you don't need this, set the parameter to 1
  input list<tuple<Integer,Integer>> ieqSccMapping;
  input SimCode.BackendMapping iBackendMapping;
  output list<SimCode.SimEqSystem> equations_;
  output list<SimCode.SimEqSystem> noDiscequations_;
  output Integer ouniqueEqIndex;
  output list<SimCodeVar.SimVar> otempvars;
  output list<tuple<Integer,Integer>> oeqSccMapping;
  output SimCode.BackendMapping oBackendMapping;
algorithm
  (equations_, noDiscequations_, ouniqueEqIndex, otempvars, oeqSccMapping, oBackendMapping) := matchcontinue (isyst, ishared, inComp)
    local
      list<BackendDAE.Equation> eqn_lst,  disc_eqn;
      list<BackendDAE.Var> var_lst,  disc_var, var_lst_1;
      BackendDAE.Variables vars_1, vars, knvars, exvars;
      BackendDAE.EquationArray eqns_1, eqns;
      Option<list<tuple<Integer, Integer, BackendDAE.Equation>>> jac;
      BackendDAE.JacobianType jac_tp;
      list<DAE.Constraint> constrs;
      list<DAE.ClassAttributes> clsAttrs;
      FCore.Cache cache;
      FCore.Graph graph;
      DAE.FunctionTree funcs;
      BackendDAE.EventInfo ev;
      list<Integer> ieqns, ivars, disc_eqns, disc_vars, eqIdcs;
      BackendDAE.ExternalObjectClasses eoc;
      list<SimCodeVar.SimVar> simVarsDisc;
      list<SimCode.SimEqSystem> discEqs;
      list<Integer>    rf, tf;
      SimCode.SimEqSystem equation_;
      BackendDAE.IncidenceMatrix  m;
      BackendDAE.IncidenceMatrixT  mt;
      BackendDAE.StrongComponent comp, comp1;
      Integer index, uniqueEqIndex, uniqueEqIndexMapping;
      BackendDAE.EqSystem syst;
      BackendDAE.Shared shared;
      String msg;
      list<SimCodeVar.SimVar> tempvars;
      list<tuple<Integer, list<Integer>>> eqnvartpllst;
      Boolean b;
      list<tuple<Integer,Integer>> tmpEqSccMapping;
      BackendDAE.ExtraInfo ei;
      BackendDAE.Jacobian jacobian;
      SimCode.BackendMapping tmpBackendMapping;
      Boolean mixedSystem;

    // EQUATIONSYSTEM: continuous system of equations
    case (BackendDAE.EQSYSTEM(orderedVars=vars, orderedEqs=eqns),
          BackendDAE.SHARED(knownVars=knvars, functionTree=funcs, info = ei),
          comp as BackendDAE.EQUATIONSYSTEM(eqns=eqIdcs,jac=jacobian,jacType=jac_tp, mixedSystem=mixedSystem))
      equation
        if Flags.isSet(Flags.FAILTRACE) then
          Debug.trace("function createOdeSystem create continuous system.\n");
        end if;
        // print("\ncreateOdeSystem -> Cont sys: ...\n");
        // extract the variables and equations of the block.
        (eqn_lst, var_lst,_) = BackendDAETransform.getEquationAndSolvedVar(comp, eqns, vars);
        // BackendDump.printEquationList(eqn_lst);
        // BackendDump.dumpVars(var_lst);
        eqn_lst = BackendEquation.replaceDerOpInEquationList(eqn_lst);
        // States are solved for der(x) not x.
        var_lst_1 = List.map(var_lst, BackendVariable.transformXToXd);
        vars_1 = BackendVariable.listVar1(var_lst_1);
        eqns_1 = BackendEquation.listEquation(eqn_lst);
        (equations_, uniqueEqIndex, tempvars) = createOdeSystem2(false, vars_1, knvars, eqns_1, jacobian, jac_tp, funcs, vars, iuniqueEqIndex, ei, mixedSystem, itempvars);
        uniqueEqIndexMapping = uniqueEqIndex-1; //a system with this index is created that contains all the equations with the indeces from iuniqueEqIndex to uniqueEqIndex-2
        //tmpEqSccMapping = List.fold1(List.intRange2(iuniqueEqIndex, uniqueEqIndex - 1), appendSccIdx, isccIndex, ieqSccMapping);
        tmpEqSccMapping = List.fold1(List.intRange2(uniqueEqIndexMapping, uniqueEqIndex - 1), appendSccIdx, isccIndex, ieqSccMapping);
        tmpBackendMapping = setEqMapping(List.intRange2(uniqueEqIndexMapping, uniqueEqIndex - 1),eqIdcs,iBackendMapping);
      then (equations_, equations_, uniqueEqIndex, tempvars, tmpEqSccMapping, tmpBackendMapping);

    // TORNSYSTEM
    case (_, _, BackendDAE.TORNSYSTEM(tearingvars=tf, residualequations=rf, otherEqnVarTpl=eqnvartpllst, jac = jacobian, linear=b, mixedSystem=mixedSystem))
      equation
        (equations_, uniqueEqIndex, tempvars) = createTornSystem(b, skipDiscInAlgorithm, tf, rf, eqnvartpllst, jacobian, isyst, ishared, iuniqueEqIndex, mixedSystem, itempvars);
        tmpEqSccMapping = appendSccIdx(uniqueEqIndex-1, isccIndex, ieqSccMapping);
        tmpBackendMapping = iBackendMapping;
      then (equations_, equations_, uniqueEqIndex, tempvars, tmpEqSccMapping, tmpBackendMapping);

    else
      equation
        msg = "function createOdeSystem failed for component " + BackendDump.strongComponentString(inComp);
        Error.addMessage(Error.INTERNAL_ERROR, {msg});
      then fail();
  end matchcontinue;
end createOdeSystem;

protected function createOdeSystem2
  input Boolean mixedEvent "true if generating the mixed system event code";
  input BackendDAE.Variables inVars;
  input BackendDAE.Variables inKnVars;
  input BackendDAE.EquationArray inEquationArray;
  input BackendDAE.Jacobian inJacobian;
  input BackendDAE.JacobianType inJacobianType;
  input DAE.FunctionTree inFuncs;
  input BackendDAE.Variables inAllVars;
  input Integer iuniqueEqIndex;
  input BackendDAE.ExtraInfo iei;
  input Boolean mixedSystem;
  input list<SimCodeVar.SimVar> itempvars;
  output list<SimCode.SimEqSystem> equations_;
  output Integer ouniqueEqIndex;
  output list<SimCodeVar.SimVar> otempvars;
algorithm
  (equations_, ouniqueEqIndex, otempvars) := matchcontinue (inJacobian, inJacobianType)
    local
      Integer uniqueEqIndex;
      list<BackendDAE.Equation> eqn_lst;
      list<DAE.ComponentRef> crefs;
      list<SimCode.SimEqSystem> resEqs;
      list<SimCodeVar.SimVar> simVars;
      list<DAE.Exp> beqs;
      list<tuple<Integer, Integer, BackendDAE.Equation>> jac;
      list<tuple<Integer, Integer, SimCode.SimEqSystem>> simJac;
      Integer linInfo;
      list<list<Real>> jacVals;
      list<Real> rhsVals, solvedVals;
      list<DAE.ElementSource> sources;
      list<DAE.ComponentRef> names;
      list<SimCodeVar.SimVar> tempvars;
      String str;
      Option<SimCode.JacobianMatrix> jacobianMatrix;
      Boolean homotopySupport;

    // constant jacobians. Linear system of equations (A x = b) where
    // A and b are constants. TODO: implement symbolic gaussian elimination
    // here. Currently uses dgesv as for next case
    case (BackendDAE.FULL_JACOBIAN(SOME(jac)), BackendDAE.JAC_CONSTANT()) equation
      if Flags.isSet(Flags.FAILTRACE) then
        Debug.trace("function createOdeSystem2 create linear system(const jacobian).\n");
      end if;
      ((simVars, _)) = BackendVariable.traverseBackendDAEVars(inVars, traversingdlowvarToSimvar, ({}, inKnVars));
      simVars = listReverse(simVars);
      (beqs, sources) = BackendDAEUtil.getEqnSysRhs(inEquationArray, inVars, SOME(inFuncs));
      beqs = listReverse(beqs);
      rhsVals = ValuesUtil.valueReals(List.map(beqs, Ceval.cevalSimple));
      jacVals = SymbolicJacobian.evaluateConstantJacobian(listLength(simVars), jac);
      (solvedVals, linInfo) = System.dgesv(jacVals, rhsVals);
      names = List.map(simVars, varName);
      checkLinearSystem(linInfo, names, jacVals, rhsVals);
      // TODO: Move these to known vars :/ This is done in the wrong phase of the compiler... Also, if done as an optimization module, we can optimize more!
      sources = List.map1(sources, DAEUtil.addSymbolicTransformation, DAE.LINEAR_SOLVED(names, jacVals, rhsVals, solvedVals));
      (equations_, uniqueEqIndex) = List.thread3MapFold(simVars, solvedVals, sources, generateSolvedEquation, iuniqueEqIndex);
    then (equations_, uniqueEqIndex, itempvars);

    // Time varying linear jacobian. Linear system of equations that needs to be solved during runtime.
    case (BackendDAE.FULL_JACOBIAN(SOME(jac)), BackendDAE.JAC_LINEAR()) equation
      if Flags.isSet(Flags.FAILTRACE) then
        Debug.trace("function createOdeSystem2 create linear system with jacobian.\n");
      end if;
      ((simVars, _)) = BackendVariable.traverseBackendDAEVars(inVars, traversingdlowvarToSimvar, ({}, inKnVars));
      simVars = listReverse(simVars);
      (beqs, sources) = BackendDAEUtil.getEqnSysRhs(inEquationArray, inVars, SOME(inFuncs));
      beqs = listReverse(beqs);
      simJac = List.map1(jac, jacToSimjac, inVars);
    then ({SimCode.SES_LINEAR(iuniqueEqIndex, mixedEvent, simVars, beqs, simJac, {}, NONE(), sources, 0)}, iuniqueEqIndex+1, itempvars);

    // Time varying nonlinear jacobian. Non-linear system of equations.
    case (_, BackendDAE.JAC_GENERIC()) equation
      if Flags.isSet(Flags.FAILTRACE) then
        Debug.trace("function createOdeSystem2 create non-linear system with jacobian.");
      end if;
      eqn_lst = BackendEquation.equationList(inEquationArray);
      crefs = BackendVariable.getAllCrefFromVariables(inVars);
      (resEqs, uniqueEqIndex, tempvars) = createNonlinearResidualEquations(eqn_lst, iuniqueEqIndex, itempvars);
      // create symbolic jacobian for simulation
      (jacobianMatrix, uniqueEqIndex, tempvars) = createSymbolicSimulationJacobian(inJacobian, uniqueEqIndex, tempvars);
      (_, homotopySupport) = BackendDAETransform.traverseExpsOfEquationList(eqn_lst, containsHomotopyCall, false);
    then ({SimCode.SES_NONLINEAR(uniqueEqIndex, resEqs, crefs, 0, jacobianMatrix, false, homotopySupport, mixedSystem)}, uniqueEqIndex+1, tempvars);

    // No analytic jacobian available. Generate non-linear system.
    case (_, _) equation
      if Flags.isSet(Flags.FAILTRACE) then
        Debug.trace("function createOdeSystem2 create non-linear system without jacobian.");
      end if;
      eqn_lst = BackendEquation.equationList(inEquationArray);
      crefs = BackendVariable.getAllCrefFromVariables(inVars);
      (resEqs, uniqueEqIndex, tempvars) = createNonlinearResidualEquations(eqn_lst, iuniqueEqIndex, itempvars);
      (_, homotopySupport) = BackendDAETransform.traverseExpsOfEquationList(eqn_lst, containsHomotopyCall, false);
    then ({SimCode.SES_NONLINEAR(uniqueEqIndex, resEqs, crefs, 0, NONE(), false, homotopySupport, mixedSystem)}, uniqueEqIndex+1, tempvars);

    // failure
    else equation
      str = BackendDump.jacobianTypeStr(inJacobianType);
      str = stringAppendList({"createOdeSystem2 failed for ", str});
      Error.addMessage(Error.INTERNAL_ERROR, {str});
    then fail();
  end matchcontinue;
end createOdeSystem2;

protected function containsHomotopyCall
  input DAE.Exp inExp;
  input Boolean inHomotopy;
  output DAE.Exp outExp;
  output Boolean outHomotopy;
protected
  BackendDAE.Variables vars;
  Boolean b;
  BackendVarTransform.VariableReplacements repl;
algorithm
  (outExp, outHomotopy) := match(inExp, inHomotopy)
    case (_, true)
    then (inExp, true);

    case (DAE.CALL(path=Absyn.IDENT(name="homotopy")), _)
    then (inExp, true);

    else (inExp, inHomotopy);
  end match;
end containsHomotopyCall;

protected function checkLinearSystem
  input Integer info;
  input list<DAE.ComponentRef> vars;
  input list<list<Real>> jac;
  input list<Real> rhs;
algorithm
  _ := matchcontinue (info, vars, jac, rhs)
    local
      String infoStr, syst, varnames, varname, rhsStr, jacStr;
    case (0, _, _, _) then ();
    case (_, _, _, _)
      equation
        true = info > 0;
        varname = ComponentReference.printComponentRefStr(listGet(vars, info));
        infoStr = intString(info);
        varnames = stringDelimitList(List.map(vars, ComponentReference.printComponentRefStr), " ;\n  ");
        rhsStr = stringDelimitList(List.map(rhs, realString), " ;\n  ");
        jacStr = stringDelimitList(List.map1(List.mapList(jac, realString), stringDelimitList, " , "), " ;\n  ");
        syst = stringAppendList({"\n[\n  ", jacStr, "\n]\n  *\n[\n  ", varnames, "\n]\n  =\n[\n  ", rhsStr, "\n]"});
        Error.addMessage(Error.LINEAR_SYSTEM_SINGULAR, {syst, infoStr, varname});
      then fail();
    case (_, _, _, _)
      equation
        true = info < 0;
        varnames = stringDelimitList(List.map(vars, ComponentReference.printComponentRefStr), " ;\n  ");
        rhsStr = stringDelimitList(List.map(rhs, realString), " ; ");
        jacStr = stringDelimitList(List.map1(List.mapList(jac, realString), stringDelimitList, " , "), " ; ");
        syst = stringAppendList({"[", jacStr, "] * [", varnames, "] = [", rhsStr, "]"});
        Error.addMessage(Error.LINEAR_SYSTEM_INVALID, {"LAPACK/dgesv", syst});
      then fail();
  end matchcontinue;
end checkLinearSystem;

protected function generateSolvedEquation
  input SimCodeVar.SimVar var;
  input Real val;
  input DAE.ElementSource source;
  input Integer iuniqueEqIndex;
  output SimCode.SimEqSystem eq;
  output Integer ouniqueEqIndex;
protected
  DAE.ComponentRef name;
algorithm
  SimCodeVar.SIMVAR(name=name) := var;
  eq := SimCode.SES_SIMPLE_ASSIGN(iuniqueEqIndex, name, DAE.RCONST(val), source);
  ouniqueEqIndex := iuniqueEqIndex+1;
end generateSolvedEquation;

protected function createTornSystem
  input Boolean linear;
  input Boolean skipDiscInAlgorithm "if true skip discrete algorithm vars";
  input list<Integer> tearingVars;
  input list<Integer> residualEqns;
  input list<tuple<Integer, list<Integer>>> otherEqns;
  input BackendDAE.Jacobian inJacobian;
  input BackendDAE.EqSystem isyst;
  input BackendDAE.Shared ishared;
  input Integer iuniqueEqIndex;
  input Boolean mixedSystem;
  input list<SimCodeVar.SimVar> itempvars;
  output list<SimCode.SimEqSystem> equations_;
  output Integer ouniqueEqIndex;
  output list<SimCodeVar.SimVar> otempvars;
algorithm
   (equations_, ouniqueEqIndex, otempvars) := match(linear, isyst, ishared)
     local
       list<BackendDAE.Var> tvars, ovarsLst;
       list<BackendDAE.Equation> reqns, otherEqnsLst;
       BackendDAE.Variables vars, kv, diffVars, ovars;
       BackendDAE.EquationArray eqns, oeqns;
       list<SimCodeVar.SimVar> tempvars, simVars;
       list<SimCode.SimEqSystem> simequations, resEqs;
       Integer uniqueEqIndex;
       list<DAE.ComponentRef> tcrs;
       DAE.FunctionTree functree;
       Option<SimCode.JacobianMatrix> jacobianMatrix;
       list<Integer> otherEqnsInts, otherVarsInts;
       list<list<Integer>> otherVarsIntsLst;
       Boolean homotopySupport;

/*
       BackendDAE.EquationArray eqns1;
       BackendDAE.Variables v;
       BackendDAE.EqSystem syst;
       list<DAE.Exp> beqs;
       list<DAE.ElementSource> sources;
       BackendVarTransform.VariableReplacements repl;

       BackendDAE.IncidenceMatrix m;
       list<tuple<Integer, Integer, BackendDAE.Equation>> jac;
       list<tuple<Integer, Integer, SimCode.SimEqSystem>> simJac;


       // for the linear case we could try just to evaluate all equation
     case(true, _, _, _, _, _, BackendDAE.EQSYSTEM(orderedVars=vars, orderedEqs=eqns), BackendDAE.SHARED(knownVars=kv, functionTree=functree), _, _)
       equation
         true = intLt(listLength(otherEqns), 12);
         //get tearing vars
         tvars = List.map1r(tearingVars, BackendVariable.getVarAt, vars);
         ((simVars, _)) = List.fold(tvars, traversingdlowvarToSimvarFold, ({}, kv));
         simVars = listReverse(simVars);
         // get residual eqns
         reqns = BackendEquation.getEqns(residualEqns, eqns);
         // solve other equations
         repl = BackendVarTransform.emptyReplacements();
         repl = solveOtherEquations(otherEqns, eqns, vars, ishared, repl);
         // replace other equations in residual equations
         (reqns, _) = BackendVarTransform.replaceEquations(reqns, repl, SOME(BackendVarTransform.skipPreOperator));
         // States are solved for der(x) not x.
         reqns = BackendEquation.replaceDerOpInEquationList(reqns);
         tvars = List.map(tvars, BackendVariable.transformXToXd);
         // generatate jacobian
         v = BackendVariable.listVar1(tvars);
         eqns1 = BackendEquation.listEquation(reqns);
         syst = BackendDAE.EQSYSTEM(v, eqns1, NONE(), NONE(), BackendDAE.NO_MATCHING(), {});
         //  BackendDump.dumpEqSystem(syst);
         (m, _) = BackendDAEUtil.incidenceMatrix(syst, BackendDAE.ABSOLUTE(), NONE());
         // calculate jacobian. If constant, linear system of equations. Otherwise nonlinear
         (SOME(jac),_) = BackendDAEUtil.calculateJacobian(v, eqns1, m, true, ishared);
         //  print(BackendDump.dumpJacobianStr(SOME(jac)) + "\n");
         // generate linear System
         (beqs, sources) = BackendDAEUtil.getEqnSysRhs(eqns1, v, SOME(functree));
         //repl = BackendVarTransform.emptyReplacements();
         //((_, beqs, _, _, _)) = BackendEquation.traverseEquationArray(eqns1, BackendDAEUtil.equationToExp, (v, {}, {}, SOME(functree), repl));
         beqs = listReverse(beqs);
         simJac = List.map1(jac, jacToSimjac, v);
         // generate other equations
         (simequations, uniqueEqIndex, tempvars) = createTornSystemOtherEqns(otherEqns, skipDiscInAlgorithm, isyst, ishared, iuniqueEqIndex+1, itempvars, {SimCode.SES_LINEAR(iuniqueEqIndex, false, simVars, beqs, sources, simJac, 0)});
       then
         (simequations, uniqueEqIndex, tempvars);
*/
     case(true, BackendDAE.EQSYSTEM(orderedVars=vars, orderedEqs=eqns), BackendDAE.SHARED(knownVars=kv)) equation
       // TODO: Remove when cpp runtime ready for doLinearTearing
       //false = stringEqual(Config.simCodeTarget(), "Cpp");
       // get tearing vars
       tvars = List.map1r(tearingVars, BackendVariable.getVarAt, vars);
       tvars = List.map(tvars, BackendVariable.transformXToXd);
       ((simVars, _)) = List.fold(tvars, traversingdlowvarToSimvarFold, ({}, kv));
       simVars = listReverse(simVars);

       // get residual eqns
       reqns = BackendEquation.getEqns(residualEqns, eqns);
       reqns = BackendEquation.replaceDerOpInEquationList(reqns);
       // generate other equations
       (simequations, uniqueEqIndex, tempvars) = createTornSystemOtherEqns(otherEqns, skipDiscInAlgorithm, isyst, ishared, iuniqueEqIndex, itempvars, {});
       (resEqs, uniqueEqIndex, tempvars) = createNonlinearResidualEquations(reqns, uniqueEqIndex, tempvars);
       simequations = listAppend(simequations, resEqs);

       (jacobianMatrix, uniqueEqIndex, tempvars) = createSymbolicSimulationJacobian(inJacobian, uniqueEqIndex, tempvars);
     then ({SimCode.SES_LINEAR(uniqueEqIndex, false, simVars, {}, {}, simequations, jacobianMatrix, {}, 0)}, uniqueEqIndex+1, tempvars);

     case(false, BackendDAE.EQSYSTEM(orderedVars=vars, orderedEqs=eqns), _) equation
       // get tearing vars
       tvars = List.map1r(tearingVars, BackendVariable.getVarAt, vars);
       tvars = List.map(tvars, BackendVariable.transformXToXd);

       // get residual eqns
       reqns = BackendEquation.getEqns(residualEqns, eqns);
       reqns = BackendEquation.replaceDerOpInEquationList(reqns);
       // generate residual replacements
       tcrs = List.map(tvars, BackendVariable.varCref);
       // generate other equations
       (simequations, uniqueEqIndex, tempvars) = createTornSystemOtherEqns(otherEqns, skipDiscInAlgorithm, isyst, ishared, iuniqueEqIndex, itempvars, {});
       (resEqs, uniqueEqIndex, tempvars) = createNonlinearResidualEquations(reqns, uniqueEqIndex, tempvars);
       simequations = listAppend(simequations, resEqs);

       (jacobianMatrix, uniqueEqIndex, tempvars) = createSymbolicSimulationJacobian(inJacobian, uniqueEqIndex, tempvars);
       (_, homotopySupport) = BackendDAETransform.traverseExpsOfEquationList(reqns, containsHomotopyCall, false);
     then ({SimCode.SES_NONLINEAR(uniqueEqIndex, simequations, tcrs, 0, jacobianMatrix, linear, homotopySupport, mixedSystem)}, uniqueEqIndex+1, tempvars);
   end match;
end createTornSystem;

protected function solveOtherEquations "author: Frenkel TUD 2011-05
  try to solve the equations"
  input list<tuple<Integer, list<Integer>>> otherEqns;
  input BackendDAE.EquationArray inEqns;
  input BackendDAE.Variables inVars;
  input BackendDAE.Shared ishared;
  input BackendVarTransform.VariableReplacements inRepl;
  output BackendVarTransform.VariableReplacements outRepl;
algorithm
  outRepl := match (otherEqns, inEqns, inVars, ishared, inRepl)
    local
      list<tuple<Integer, list<Integer>>> rest;
      Integer v, e;
      DAE.Exp e1, e2, varexp, expr;
      DAE.ComponentRef cr, dcr;
      DAE.ElementSource source;
      BackendVarTransform.VariableReplacements repl;
      BackendDAE.Var var;
      list<BackendDAE.Var> otherVars, varlst;
      list<Integer> ds, vlst;
      list<DAE.Exp> explst1, explst2;
      BackendDAE.Equation eqn;
      list<list<DAE.Subscript>> subslst;
      DAE.FunctionTree funcs;

    case ({}, _, _, _, _) then inRepl;
    case ((e, {v})::rest, _, _, _, _)
      equation
        (BackendDAE.EQUATION(exp=e1, scalar=e2)) = BackendEquation.equationNth1(inEqns, e);
        (var as BackendDAE.VAR(varName=cr)) = BackendVariable.getVarAt(inVars, v);
        varexp = Expression.crefExp(cr);
        varexp = if BackendVariable.isStateVar(var) then Expression.expDer(varexp) else varexp;
        BackendDAE.SHARED(functionTree = funcs) = ishared;
        (expr, {}) = ExpressionSolve.solve2(e1, e2, varexp, SOME(funcs));
        dcr = if BackendVariable.isStateVar(var) then ComponentReference.crefPrefixDer(cr) else cr;
        repl = BackendVarTransform.addReplacement(inRepl, dcr, expr, SOME(BackendVarTransform.skipPreOperator));
        repl = if BackendVariable.isStateVar(var) then BackendVarTransform.addDerConstRepl(cr, expr, repl) else repl;
        // BackendDump.debugStrCrefStrExpStr(("", cr, " := ", expr, "\n"));
      then
        solveOtherEquations(rest, inEqns, inVars, ishared, repl);
    case ((e, vlst)::rest, _, _, _, _)
      equation
        (BackendDAE.ARRAY_EQUATION(dimSize=ds, left=e1, right=e2)) = BackendEquation.equationNth1(inEqns, e);
        varlst = List.map1r(vlst, BackendVariable.getVarAt, inVars);
        subslst = Expression.dimensionSizesSubscripts(ds);
        subslst = Expression.rangesToSubscripts(subslst);
        explst1 = List.map1r(subslst, Expression.applyExpSubscripts, e1);
        explst1 = ExpressionSimplify.simplifyList(explst1, {});
        explst2 = List.map1r(subslst, Expression.applyExpSubscripts, e2);
        explst2 = ExpressionSimplify.simplifyList(explst2, {});
        repl = solveOtherEquations1(explst1, explst2, varlst, inVars, ishared, inRepl);
      then
        solveOtherEquations(rest, inEqns, inVars, ishared, repl);
  end match;
end solveOtherEquations;

protected function solveOtherEquations1 "author: Frenkel TUD 2011-05
  try to solve the equations"
  input list<DAE.Exp> iExps1;
  input list<DAE.Exp> iExps2;
  input list<BackendDAE.Var> iVars;
  input BackendDAE.Variables inVars;
  input BackendDAE.Shared ishared;
  input BackendVarTransform.VariableReplacements inRepl;
  output BackendVarTransform.VariableReplacements outRepl;
algorithm
  outRepl :=
  match (iExps1, iExps2, iVars, inVars, ishared, inRepl)
    local
      DAE.Exp e1, e2, varexp, expr;
      DAE.ComponentRef cr, dcr;
      BackendVarTransform.VariableReplacements repl;
      BackendDAE.Var var;
      list<BackendDAE.Var> otherVars, rest;
      list<DAE.Exp> explst1, explst2;
      DAE.FunctionTree funcs;
    case ({}, _, _, _, _, _) then inRepl;
    case (e1::explst1, e2::explst2, (var as BackendDAE.VAR(varName=cr))::rest, _, _, _)
      equation
        varexp = Expression.crefExp(cr);
        varexp = if BackendVariable.isStateVar(var) then Expression.expDer(varexp) else varexp;
        BackendDAE.SHARED(functionTree = funcs) = ishared;
        (expr, {}) = ExpressionSolve.solve2(e1, e2, varexp, SOME(funcs));
        dcr = if BackendVariable.isStateVar(var) then ComponentReference.crefPrefixDer(cr) else cr;
        repl = BackendVarTransform.addReplacement(inRepl, dcr, expr, SOME(BackendVarTransform.skipPreOperator));
        repl = if BackendVariable.isStateVar(var) then BackendVarTransform.addDerConstRepl(cr, expr, repl) else repl;
        // BackendDump.debugStrCrefStrExpStr(("", cr, " := ", expr, "\n"));
      then
        solveOtherEquations1(explst1, explst2, rest, inVars, ishared, repl);
  end match;
end solveOtherEquations1;

protected function createTornSystemOtherEqns
  input list<tuple<Integer, list<Integer>>> otherEqns;
  input Boolean skipDiscInAlgorithm "if true skip discrete algorithm vars";
  input BackendDAE.EqSystem isyst;
  input BackendDAE.Shared ishared;
  input Integer iuniqueEqIndex;
  input list<SimCodeVar.SimVar> itempvars;
  input list<SimCode.SimEqSystem> isimequations;
  output list<SimCode.SimEqSystem> equations_;
  output Integer ouniqueEqIndex;
  output list<SimCodeVar.SimVar> otempvars;
algorithm
   (equations_, ouniqueEqIndex, otempvars) :=
   match(otherEqns, skipDiscInAlgorithm, isyst, ishared, iuniqueEqIndex, itempvars, isimequations)
     local
       BackendDAE.EquationArray eqns;
       list<SimCodeVar.SimVar> tempvars;
       list<SimCode.SimEqSystem> simequations;
       Integer uniqueEqIndex, eqnindx;
       BackendDAE.Equation eqn;
       list<Integer> vars;
       list<tuple<Integer, list<Integer>>> rest;
       BackendDAE.StrongComponent comp;

     case({}, _, _, _, _, _, _)
     then (isimequations, iuniqueEqIndex, itempvars);

     case((eqnindx, vars)::rest, _, BackendDAE.EQSYSTEM(orderedEqs=eqns), _, _, _, _) equation
       // get Eqn
       eqn = BackendEquation.equationNth1(eqns, eqnindx);
       // generate comp
       comp = createTornSystemOtherEqns1(eqn, eqnindx, vars);
       (simequations, _, uniqueEqIndex, tempvars) = createEquations(true, false, true, skipDiscInAlgorithm, isyst, ishared, {comp}, iuniqueEqIndex, itempvars);
       simequations = listAppend(isimequations, simequations);
       // generade other equations
       (simequations, uniqueEqIndex, tempvars) = createTornSystemOtherEqns(rest, skipDiscInAlgorithm, isyst, ishared, uniqueEqIndex, tempvars, simequations);
     then (simequations, uniqueEqIndex, tempvars);
   end match;
end createTornSystemOtherEqns;

protected function createTornSystemOtherEqns1
  input BackendDAE.Equation eqn;
  input Integer eqnindx;
  input list<Integer> varindx;
  output BackendDAE.StrongComponent ocomp;
algorithm
  ocomp := match(eqn, eqnindx, varindx)
    local
      Integer v;
    case (BackendDAE.EQUATION(), _, v::{})
      then
        BackendDAE.SINGLEEQUATION(eqnindx, v);
    case (BackendDAE.RESIDUAL_EQUATION(), _, v::{})
      then
        BackendDAE.SINGLEEQUATION(eqnindx, v);
    case (BackendDAE.SOLVED_EQUATION(), _, v::{})
      then
        BackendDAE.SINGLEEQUATION(eqnindx, v);
    case (BackendDAE.ARRAY_EQUATION(), _, _)
      then
        BackendDAE.SINGLEARRAY(eqnindx, varindx);
    case (BackendDAE.IF_EQUATION(), _, _)
      then
        BackendDAE.SINGLEIFEQUATION(eqnindx, varindx);
    case (BackendDAE.ALGORITHM(), _, _)
      then
        BackendDAE.SINGLEALGORITHM(eqnindx, varindx);
    case (BackendDAE.COMPLEX_EQUATION(), _, _)
      then
        BackendDAE.SINGLECOMPLEXEQUATION(eqnindx, varindx);
    case (BackendDAE.WHEN_EQUATION(size=_), _, _)
      then
        BackendDAE.SINGLEWHENEQUATION(eqnindx, varindx);

    else
      equation
        print("SimCodeUtil.createTornSystemOtherEqns1 failed for\n");
        BackendDump.printEquationList({eqn});
        print("Eqn: " + intString(eqnindx) + " Vars: " + stringDelimitList(List.map(varindx, intString), ", ") + "\n");
      then
        fail();
  end match;
end createTornSystemOtherEqns1;

// =============================================================================
// section to create state set equations
//
// =============================================================================

public function createStateSets
"author: Frenkel TUD 2012
  This function handle states sets for code generation."
  input BackendDAE.BackendDAE inDAE;
  input list<SimCode.StateSet> iEquations;
  input Integer iuniqueEqIndex;
  input list<SimCodeVar.SimVar> itempvars;
  output BackendDAE.BackendDAE outDAE;
  output list<SimCode.StateSet> oEquations;
  output Integer ouniqueEqIndex;
  output list<SimCodeVar.SimVar> otempvars;
  output Integer numStateSets;
protected
  Boolean flag;
algorithm
  (outDAE, (oEquations, ouniqueEqIndex, otempvars, numStateSets)) :=
    BackendDAEUtil.mapEqSystemAndFold(inDAE, createStateSetsSystem, (iEquations, iuniqueEqIndex, itempvars, 0));
  // BackendDump.printBackendDAE(outDAE);
end createStateSets;

protected function createStateSetsSystem "author: Frenkel TUD 2012-12
  traverse an Equationsystem to handle states sets"
  input BackendDAE.EqSystem isyst;
  input BackendDAE.Shared inShared;
  input tuple<list<SimCode.StateSet>, Integer, list<SimCodeVar.SimVar>, Integer> inTpl;
  output BackendDAE.EqSystem osyst;
  output BackendDAE.Shared outShared := inShared;
  output tuple<list<SimCode.StateSet>, Integer, list<SimCodeVar.SimVar>, Integer> outTpl;
algorithm
  (osyst, outTpl):= match (isyst, inTpl)
    local
      BackendDAE.Variables vars;
      BackendDAE.EquationArray eqns;
      Option<BackendDAE.IncidenceMatrix> m;
      Option<BackendDAE.IncidenceMatrixT> mT;
      BackendDAE.Matching matching;
      BackendDAE.StateSets stateSets;
      BackendDAE.BaseClockPartitionKind partitionKind;
      list<SimCode.StateSet> equations;
      Integer uniqueEqIndex, numStateSets;
      list<SimCodeVar.SimVar> tempvars;
      BackendDAE.StrongComponents comps;
    // no stateSet
    case (BackendDAE.EQSYSTEM(stateSets={}), _) then (isyst, inTpl);
    // sets
    case (BackendDAE.EQSYSTEM(orderedVars=vars, orderedEqs=eqns, m=m, mT=mT, matching=matching as BackendDAE.MATCHING(comps=comps), stateSets=stateSets, partitionKind=partitionKind),
         (equations, uniqueEqIndex, tempvars, numStateSets))
      equation
        (vars, equations, uniqueEqIndex, tempvars, numStateSets) = createStateSetsSets(stateSets, vars, eqns, inShared, comps, equations, uniqueEqIndex, tempvars, numStateSets);
      then
        (BackendDAE.EQSYSTEM(vars, eqns, m, mT, matching, stateSets, partitionKind), (equations, uniqueEqIndex, tempvars, numStateSets));
  end match;
end createStateSetsSystem;

protected function createStateSetsSets
  input BackendDAE.StateSets iStateSets;
  input BackendDAE.Variables iVars;
  input BackendDAE.EquationArray iEqns;
  input BackendDAE.Shared shared;
  input BackendDAE.StrongComponents comps;
  input list<SimCode.StateSet> iEquations;
  input Integer iuniqueEqIndex;
  input list<SimCodeVar.SimVar> itempvars;
  input Integer iNumStateSets;
  output BackendDAE.Variables oVars;
  output list<SimCode.StateSet> oEquations;
  output Integer ouniqueEqIndex;
  output list<SimCodeVar.SimVar> otempvars;
  output Integer oNumStateSets;
algorithm
  (oVars, oEquations, ouniqueEqIndex, otempvars, oNumStateSets) :=
  matchcontinue(iStateSets, iVars, iEqns, shared, comps, iEquations, iuniqueEqIndex, itempvars, iNumStateSets)
    local
      DAE.FunctionTree functree;
      BackendDAE.StateSets sets;
      Integer rang, numStateSets, nCandidates;
      list<DAE.ComponentRef> crset;
      DAE.ComponentRef crA, crJ;
      BackendDAE.Variables vars, knVars;
      list<BackendDAE.Var> aVars, statevars, dstatesvars, varJ, compvars;
      list<BackendDAE.Equation> ceqns, oeqns, compeqns;
      list<DAE.ComponentRef> crstates;
      SimCode.JacobianMatrix jacobianMatrix;
      list<SimCode.StateSet> simequations;
      list<SimCodeVar.SimVar> tempvars;
      Integer uniqueEqIndex;
      HashSet.HashSet hs;
      array<Boolean> marked;
      BackendDAE.ExtraInfo ei;
      BackendDAE.Jacobian jacobian;
      String errorMessage;

    case({}, _, _, _, _, _, _, _, _) then (iVars, iEquations, iuniqueEqIndex, itempvars, iNumStateSets);

    case(BackendDAE.STATESET(rang=rang, state=crset, crA=crA, varA=aVars, statescandidates=statevars,   jacobian=jacobian)::sets, _, _,
         _, _, _, _, _, _)
      equation
        // get state names
        crstates = List.map(statevars, BackendVariable.varCref);

        // add vars for A
        vars = BackendVariable.addVars(aVars, iVars);

        // get first a element for varinfo
        crA = ComponentReference.subscriptCrefWithInt(crA, 1);
        crA = if intGt(listLength(crset), 1) then ComponentReference.subscriptCrefWithInt(crA, 1) else crA;

        // number of states
        nCandidates = listLength(statevars);

        // create symbolic jacobian for simulation
        (SOME(jacobianMatrix), uniqueEqIndex, tempvars) = createSymbolicSimulationJacobian(jacobian, iuniqueEqIndex, itempvars);

        // next set
        (vars, simequations, uniqueEqIndex, tempvars, numStateSets) = createStateSetsSets(sets, vars, iEqns, shared, comps, SimCode.SES_STATESET(iuniqueEqIndex, nCandidates, rang, crset, crstates, crA, jacobianMatrix)::iEquations, uniqueEqIndex, tempvars, iNumStateSets+1);
      then
        (vars, simequations, uniqueEqIndex, tempvars, numStateSets);
    else
      equation
        errorMessage = "function createStateSetsSets failed.";
        Error.addMessage(Error.INTERNAL_ERROR, {errorMessage});
      then
        fail();
  end matchcontinue;
end createStateSetsSets;

protected function indexStateSets
" function to collect jacobians for statesets"
  input list<SimCode.StateSet> inSets;
  input list<SimCode.JacobianMatrix> inSymJacs;
  input Integer iNumJac;
  input list<SimCode.StateSet> inSetsAccum;
  output list<SimCode.StateSet> outSets;
  output list<SimCode.JacobianMatrix> outSymJacs;
  output Integer oNumJac;
algorithm
  (outSets, outSymJacs, oNumJac) := match(inSets, inSymJacs, iNumJac, inSetsAccum)
    local
      list<SimCode.StateSet> sets;
      SimCode.StateSet set;
      SimCode.JacobianMatrix symJac;
      Integer numJac;
      Integer index;
      Integer nCandidates;
      Integer nStates;
      list<DAE.ComponentRef> states;
      list<DAE.ComponentRef> statescandidates;
      DAE.ComponentRef crA;
    case ({}, _, _, _) then (listReverse(inSetsAccum), listReverse(inSymJacs), iNumJac);
    case((SimCode.SES_STATESET(index=index, nCandidates=nCandidates, nStates=nStates, states=states, statescandidates=statescandidates, crA=crA, jacobianMatrix=symJac))::sets, _, _, _)
    equation
      (symJac, _, _, _, numJac, _) = countandIndexAlgebraicLoopsSymJac(symJac, 0, 0, 0, iNumJac);
      (outSets, outSymJacs, oNumJac) = indexStateSets(sets, symJac::inSymJacs, numJac, SimCode.SES_STATESET(index, nCandidates, nStates, states, statescandidates, crA, symJac)::inSetsAccum);
     then (outSets, outSymJacs, oNumJac);
  end match;
end indexStateSets;

// =============================================================================
// section to create SimCode symbolic jacobian from BackendDAE.Equations
//
// =============================================================================

protected function createSymbolicSimulationJacobian "fuction createSymbolicSimulationJacobian
  author: wbraun
  function creates a symbolic jacobian column for
  non-linear systems and tearing systems."
  input BackendDAE.Jacobian inJacobian;
  input Integer iuniqueEqIndex;
  input list<SimCodeVar.SimVar> itempvars;
  output Option<SimCode.JacobianMatrix> res;
  output Integer ouniqueEqIndex;
  output list<SimCodeVar.SimVar> otempvars;
algorithm
  (res, ouniqueEqIndex, otempvars) := matchcontinue(inJacobian, iuniqueEqIndex, itempvars)
  local

    BackendDAE.Variables emptyVars, dependentVars, independentVars, knvars, allvars,  residualVars;
    BackendDAE.EquationArray emptyEqns, eqns;
    list<BackendDAE.Var> knvarLst, independentVarsLst, dependentVarsLst, residualVarsLst;
    list<DAE.ComponentRef> independentComRefs, dependentVarsComRefs;

    DAE.ComponentRef x;
    BackendDAE.SparseColoring sparseColoring;
    list<tuple<DAE.ComponentRef, list<DAE.ComponentRef>>> sparsepatternComRefs;

    BackendDAE.EqSystem syst;
    BackendDAE.Shared shared;
    BackendDAE.StrongComponents comps;

    list<SimCodeVar.SimVar> tempvars;
    String name, s, dummyVar;
    Integer maxColor, uniqueEqIndex;

    list<SimCode.SimEqSystem> columnEquations;
    list<SimCodeVar.SimVar> columnVars;
    list<SimCodeVar.SimVar> seedVars, indexVars;

    String errorMessage;

    DAE.FunctionTree funcs;

    case (BackendDAE.EMPTY_JACOBIAN(), _, _) then (NONE(), iuniqueEqIndex, itempvars);

    case (BackendDAE.FULL_JACOBIAN(_), _, _) then (NONE(), iuniqueEqIndex, itempvars);

    case (BackendDAE.GENERIC_JACOBIAN((BackendDAE.DAE(eqs={syst as BackendDAE.EQSYSTEM(matching=BackendDAE.MATCHING(comps=comps))},
                                    shared=shared), name,
                                    independentVarsLst, residualVarsLst, dependentVarsLst),
                                      (sparsepatternComRefs, _, (_, _)),
                                      sparseColoring), _, _)
      equation
        // createSymbolicJacobianssSimCode
        if Flags.isSet(Flags.JAC_DUMP2) then
          print("analytical Jacobians -> creating SimCode equations for Matrix " + name + " time: " + realString(clock()) + "\n");
        end if;
        (columnEquations, _, uniqueEqIndex, tempvars) = createEquations(false, false, false, false, syst, shared, comps, iuniqueEqIndex, itempvars);
        if Flags.isSet(Flags.JAC_DUMP2) then
          print("analytical Jacobians -> created all SimCode equations for Matrix " + name +  " time: " + realString(clock()) + "\n");
        end if;

        // create SimCodeVar.SimVars from jacobian vars
        dummyVar = ("dummyVar" + name);
        x = DAE.CREF_IDENT(dummyVar, DAE.T_REAL_DEFAULT, {});

        residualVars = BackendVariable.listVar1(residualVarsLst);
        columnVars = createAllDiffedSimVars(dependentVarsLst, x, residualVars, 0, (name, false), {});

        if Flags.isSet(Flags.JAC_DUMP2) then
          print("\n---+++ diffed column variables +++---\n");
          print(Tpl.tplString(SimCodeDump.dumpVarsShort, columnVars));
        end if;

        // all differentiated vars
        // ((columnVarsKn, _)) =  BackendVariable.traverseBackendDAEVars(allvars, traversingdlowvarToSimvar, ({}, emptyVars));
        // columnVars = listAppend(columnVars, columnVarsKn);
        columnVars = listReverse(columnVars);

        if Flags.isSet(Flags.JAC_DUMP2) then
          print("\n---+++ all column variables +++---\n");
          print(Tpl.tplString(SimCodeDump.dumpVarsShort, columnVars));
          print("analytical Jacobians -> create all SimCode vars for Matrix " + name + " time: " + realString(clock()) + "\n");
        end if;

        independentVars = BackendVariable.listVar1(independentVarsLst);
        emptyVars =  BackendVariable.emptyVars();
        ((seedVars, _)) =  BackendVariable.traverseBackendDAEVars(independentVars, traversingdlowvarToSimvar, ({}, emptyVars));
        ((indexVars, _)) =  BackendVariable.traverseBackendDAEVars(residualVars, traversingdlowvarToSimvar, ({}, emptyVars));
        seedVars = listReverse(seedVars);
        indexVars = listReverse(indexVars);
        if Flags.isSet(Flags.JAC_DUMP2) then
          print("\n---+++ seedVars variables +++---\n");
          print(Tpl.tplString(SimCodeDump.dumpVarsShort, seedVars));
          print("\n---+++ indexVars variables +++---\n");
          print(Tpl.tplString(SimCodeDump.dumpVarsShort, indexVars));
        end if;

        // set sparse pattern
        maxColor = listLength(sparseColoring);
        s =  intString(listLength(residualVarsLst));

        if Flags.isSet(Flags.JAC_DUMP2) then
          print("analytical Jacobians -> transformed to SimCode for Matrix " + name + " time: " + realString(clock()) + "\n");
        end if;

        then (SOME(({(columnEquations, columnVars, s)}, seedVars, name, (sparsepatternComRefs, {}, (seedVars, indexVars)), sparseColoring, maxColor, -1)), uniqueEqIndex, tempvars);

    case(_, _, _)
      equation
        true = Flags.isSet(Flags.JAC_DUMP);
        errorMessage = "function createSymbolicSimulationJacobian failed.";
        Error.addMessage(Error.INTERNAL_ERROR, {errorMessage});
      then (NONE(), iuniqueEqIndex, itempvars);

    else (NONE(), iuniqueEqIndex, itempvars);

  end matchcontinue;
end createSymbolicSimulationJacobian;

protected function createJacobianLinearCode
  input BackendDAE.SymbolicJacobians inSymjacs;
  input SimCode.ModelInfo inModelInfo;
  input Integer iuniqueEqIndex;
  output list<SimCode.JacobianMatrix> res;
  output Integer ouniqueEqIndex;
algorithm
  (res,ouniqueEqIndex) := matchcontinue (inSymjacs, inModelInfo, iuniqueEqIndex)
    local
    case (_, _, _)
      equation
        // b = Flags.disableDebug(Flags.EXEC_STAT);
        // The jacobian code requires single systems;
        // I did not rewrite it to take advantage of any parallelism in the code
        (res, ouniqueEqIndex) = createSymbolicJacobianssSimCode(inSymjacs, inModelInfo, iuniqueEqIndex, {"A", "B", "C", "D"});
        // if optModule is not activated add dummy matrices
        res = addLinearizationMatrixes(res);
        // _ = Flags.set(Flags.EXEC_STAT, b);
        execStat("SimCode generated analytical Jacobians");
      then (res,ouniqueEqIndex);
    else
      equation
        res = {({}, {}, "A", ({}, {}, ({}, {})), {}, 0, -1), ({}, {}, "B", ({}, {}, ({}, {})), {}, 0, -1), ({}, {}, "C", ({}, {}, ({}, {})), {}, 0, -1), ({}, {}, "D", ({}, {}, ({}, {})), {}, 0, -1)};
      then (res,iuniqueEqIndex);
  end matchcontinue;
end createJacobianLinearCode;

protected function createSymbolicJacobianssSimCode
"fuction creates the linear model matrices column-wise
 author: wbraun"
  input BackendDAE.SymbolicJacobians inSymJacobians;
  input SimCode.ModelInfo inModelInfo;
  input Integer iuniqueEqIndex;
  input list<String> inNames;
  output list<SimCode.JacobianMatrix> outJacobianMatrixes;
  output Integer ouniqueEqIndex;
algorithm
  (outJacobianMatrixes, ouniqueEqIndex) :=
  matchcontinue (inSymJacobians, inModelInfo, iuniqueEqIndex, inNames)
    local
      BackendDAE.EqSystem syst;
      BackendDAE.Shared shared;
      BackendDAE.StrongComponents comps;
      BackendDAE.Variables vars, knvars, empty;

      DAE.ComponentRef x;
      list<BackendDAE.Var>  diffVars, diffedVars, alldiffedVars;
      list<DAE.ComponentRef> diffCompRefs, diffedCompRefs;

      Integer uniqueEqIndex;

      list<String> restnames;
      String name, s, dummyVar;

      SimCodeVar.SimVars simvars;
      list<SimCode.SimEqSystem> columnEquations;
      list<SimCodeVar.SimVar> columnVars;
      list<SimCodeVar.SimVar> columnVarsKn;
      list<SimCodeVar.SimVar> seedVars, indexVars;

      list<tuple<DAE.ComponentRef, list<DAE.ComponentRef>>> sparsepattern, sparsepatternT;
      list<list<DAE.ComponentRef>> colsColors;
      Integer maxColor;

      BackendDAE.SymbolicJacobians rest;
      list<SimCode.JacobianMatrix> linearModelMatrices;

    case ({}, _, _, _) then ({}, iuniqueEqIndex);
    // if nothing is generated
    case (((NONE(), ({}, {}, ({}, {})), {}))::rest, _, _, name::restnames)
      equation
        (linearModelMatrices, uniqueEqIndex) = createSymbolicJacobianssSimCode(rest, inModelInfo, iuniqueEqIndex, restnames);
        linearModelMatrices = (({}, {}, name, ({}, {}, ({}, {})), {}, 0, -1))::linearModelMatrices;
     then
        (linearModelMatrices, uniqueEqIndex);

    // if only sparsity pattern is generated
    case (((NONE(), (sparsepattern, sparsepatternT, (diffCompRefs, diffedCompRefs)), colsColors))::rest, SimCode.MODELINFO(vars=simvars), _, name::restnames)
      equation

        (_, (_, seedVars)) = traveseSimVars(simvars, findSimVarsCompare, (diffCompRefs, {}));
        if Flags.isSet(Flags.JAC_DUMP2) then
          print("diffCrefs: " + ComponentReference.printComponentRefListStr(diffCompRefs) + "\n");
          print("\n---+++  seedVars +++---\n");
          print(Tpl.tplString(SimCodeDump.dumpVarsShort, seedVars));
        end if;


        (_, (_, indexVars)) = traveseSimVars(simvars, findSimVarsCompare, (diffedCompRefs, {}));
        if Flags.isSet(Flags.JAC_DUMP2) then
          print("diffedCrefs: " + ComponentReference.printComponentRefListStr(diffedCompRefs) + "\n");
          print("\n---+++  indexVars +++---\n");
          print(Tpl.tplString(SimCodeDump.dumpVarsShort, indexVars));
        end if;

        maxColor = listLength(colsColors);
        s = intString(listLength(diffedCompRefs));

        (linearModelMatrices, uniqueEqIndex) = createSymbolicJacobianssSimCode(rest, inModelInfo, iuniqueEqIndex, restnames);
        linearModelMatrices = (({(({}, {}, s))}, seedVars, name, (sparsepattern, sparsepatternT, (seedVars, indexVars)), colsColors, maxColor, -1))::linearModelMatrices;
     then
        (linearModelMatrices, uniqueEqIndex);

    case (((SOME((BackendDAE.DAE(eqs={syst as BackendDAE.EQSYSTEM(matching=BackendDAE.MATCHING(comps=comps))},
                                    shared=shared), name,
                                    _, diffedVars, alldiffedVars)), (sparsepattern, sparsepatternT, (diffCompRefs, diffedCompRefs)), colsColors))::rest,
                                    SimCode.MODELINFO(vars=simvars), _, _::restnames)
      equation
        if Flags.isSet(Flags.JAC_DUMP2) then
          print("analytical Jacobians -> creating SimCode equations for Matrix " + name + " time: " + realString(clock()) + "\n");
        end if;
        (columnEquations, _, uniqueEqIndex, _) = createEquations(false, false, false, false, syst, shared, comps, iuniqueEqIndex, {});
        if Flags.isSet(Flags.JAC_DUMP2) then
          print("analytical Jacobians -> created all SimCode equations for Matrix " + name +  " time: " + realString(clock()) + "\n");
        end if;

        // create SimCodeVar.SimVars from jacobian vars
        dummyVar = ("dummyVar" + name);
        x = DAE.CREF_IDENT(dummyVar, DAE.T_REAL_DEFAULT, {});
        vars = BackendVariable.listVar1(diffedVars);

        //sort variable for index
        empty = BackendVariable.listVar(alldiffedVars);
        (_, (_, alldiffedVars)) = traveseSimVars(simvars, findSimVarsinAllVar, (empty, {}));
        alldiffedVars = listReverse(alldiffedVars);
        columnVars = createAllDiffedSimVars(alldiffedVars, x, vars, 0, (name, false), {});

        /*
        knvars = BackendVariable.daeKnVars(shared);
        empty = BackendVariable.emptyVars();
        ((columnVarsKn, _)) =  BackendVariable.traverseBackendDAEVars(knvars, traversingdlowvarToSimvar, ({}, empty));
        columnVars = List.unique(columnVars, columnVarsKn);
        columnVars = listReverse(columnVars);
        */

        if Flags.isSet(Flags.JAC_DUMP2) then
          print("analytical Jacobians -> create all SimCode vars for Matrix " + name + " time: " + realString(clock()) + "\n");
        end if;

        (_, (_, seedVars)) = traveseSimVars(simvars, findSimVarsCompare, (diffCompRefs, {}));
        if Flags.isSet(Flags.JAC_DUMP2) then
          print("diffCrefs: " + ComponentReference.printComponentRefListStr(diffCompRefs) + "\n");
          print("\n---+++  seedVars +++---\n");
          print(Tpl.tplString(SimCodeDump.dumpVarsShort, seedVars));
        end if;

        (_, (_, indexVars)) = traveseSimVars(simvars, findSimVarsCompare, (diffedCompRefs, {}));
        if Flags.isSet(Flags.JAC_DUMP2) then
          print("diffedCrefs: " + ComponentReference.printComponentRefListStr(diffedCompRefs) + "\n");
          print("\n---+++  indexVars +++---\n");
          print(Tpl.tplString(SimCodeDump.dumpVarsShort, indexVars));
        end if;

        maxColor = listLength(colsColors);
        s =  intString(listLength(diffedVars));

        if Flags.isSet(Flags.JAC_DUMP2) then
          print("analytical Jacobians -> transformed to SimCode for Matrix " + name + " time: " + realString(clock()) + "\n");
        end if;

        (linearModelMatrices, uniqueEqIndex) = createSymbolicJacobianssSimCode(rest, inModelInfo, uniqueEqIndex, restnames);
        linearModelMatrices = (({((columnEquations, columnVars, s))}, seedVars, name, (sparsepattern, sparsepatternT, (seedVars, indexVars)), colsColors, maxColor, -1))::linearModelMatrices;
     then
        (linearModelMatrices, uniqueEqIndex);
    else
      equation
        Error.addMessage(Error.INTERNAL_ERROR, {"Generation of symbolic matrix SimCode (SimCode.createSymbolicJacobianssSimCode) failed"});
      then
        fail();
  end matchcontinue;
end createSymbolicJacobianssSimCode;

protected function findSimVarsCompare
   input tuple<SimCodeVar.SimVar, tuple<list<DAE.ComponentRef>, list<SimCodeVar.SimVar>>> inTuple;
    output tuple<SimCodeVar.SimVar, tuple<list<DAE.ComponentRef>, list<SimCodeVar.SimVar>>> outTuple;
   algorithm
       outTuple := matchcontinue(inTuple)
       local
         DAE.ComponentRef cref;
         list<DAE.ComponentRef> crefs;
         list<SimCodeVar.SimVar> simvars;
         SimCodeVar.SimVar var;
       case((var as (SimCodeVar.SIMVAR(name=cref)), (crefs, simvars)))
         equation
           true = listMember(cref, crefs);
           true = not List.isMemberOnTrue(var, simvars, compareSimVarName);
         then ((var, (crefs,  listAppend(simvars, {var}))));
       case(_) then inTuple;
       end matchcontinue;
end findSimVarsCompare;


protected function findSimVarsinAllVar
   input tuple<SimCodeVar.SimVar, tuple<BackendDAE.Variables, list<BackendDAE.Var>>> inTuple;
    output tuple<SimCodeVar.SimVar, tuple<BackendDAE.Variables, list<BackendDAE.Var>>> outTuple;
   algorithm
       outTuple := matchcontinue(inTuple)
       local
         DAE.ComponentRef cref;
         list<BackendDAE.Var> resvars;
         BackendDAE.Variables vars;
         BackendDAE.Var v;
         SimCodeVar.SimVar var;
       case((var as (SimCodeVar.SIMVAR(name=cref)), (vars, resvars)))
         equation
           ({v},_) = BackendVariable.getVar(cref, vars);
           true = not List.isMemberOnTrue(v, resvars, BackendVariable.varEqual);
         then ((var, (vars, v::resvars)));
       case(_) then inTuple;
       end matchcontinue;
end findSimVarsinAllVar;


protected function compareSimVarName
  input SimCodeVar.SimVar var;
  input SimCodeVar.SimVar var1;
  output Boolean b;
   algorithm
       b := matchcontinue(var, var1)
         local
           DAE.ComponentRef name, name1;
         case (SimCodeVar.SIMVAR(name = name), SimCodeVar.SIMVAR(name = name1))
           equation
             true = ComponentReference.crefEqual(name, name1);
           then true;

         else false;
       end matchcontinue;
end compareSimVarName;

protected function createAllDiffedSimVars "author: wbraun"
  input list<BackendDAE.Var> inVars;
  input DAE.ComponentRef inCref;
  input BackendDAE.Variables inAllVars;
  input Integer inIndex;
  input tuple<String, Boolean> inMatrixName;
  input list<SimCodeVar.SimVar> iVars;
  output list<SimCodeVar.SimVar> outVars;
algorithm
  outVars := matchcontinue(inVars, inCref, inAllVars, inIndex, inMatrixName, iVars)
  local
    BackendDAE.Var  v1;
    SimCodeVar.SimVar r1;
    DAE.ComponentRef currVar, cref, derivedCref;
    list<BackendDAE.Var> restVar;
    Option<DAE.VariableAttributes> dae_var_attr;
    Boolean isProtected;

    case({}, _, _, _, _, _)
    then listReverse(iVars);
    // skip for dicrete variable
    case(BackendDAE.VAR(varKind=BackendDAE.DISCRETE())::restVar, cref, _, _, _, _) equation
     then
       createAllDiffedSimVars(restVar, cref, inAllVars, inIndex, inMatrixName, iVars);

     case(BackendDAE.VAR(varName=currVar, varKind=BackendDAE.STATE(), values = dae_var_attr)::restVar, cref, _, _, _, _) equation
      ({_}, _) = BackendVariable.getVar(currVar, inAllVars);
      currVar = ComponentReference.crefPrefixDer(currVar);
      derivedCref = Differentiate.differentiateVarWithRespectToX(currVar, cref, inMatrixName);
      isProtected = getProtected(dae_var_attr);
      r1 = SimCodeVar.SIMVAR(derivedCref, BackendDAE.STATE_DER(), "", "", "", inIndex, NONE(), NONE(), NONE(), NONE(), false, DAE.T_REAL_DEFAULT, false, NONE(), SimCodeVar.NOALIAS(), DAE.emptyElementSource, SimCodeVar.NONECAUS(), NONE(), {}, false, isProtected);
    then
      createAllDiffedSimVars(restVar, cref, inAllVars, inIndex+1, inMatrixName, r1::iVars);

    case(BackendDAE.VAR(varName=currVar, values = dae_var_attr)::restVar, cref, _, _, _, _) equation
      ({_}, _) = BackendVariable.getVar(currVar, inAllVars);
      derivedCref = Differentiate.differentiateVarWithRespectToX(currVar, cref, inMatrixName);
      isProtected = getProtected(dae_var_attr);
      r1 = SimCodeVar.SIMVAR(derivedCref, BackendDAE.STATE_DER(), "", "", "", inIndex, NONE(), NONE(), NONE(), NONE(), false, DAE.T_REAL_DEFAULT, false, NONE(), SimCodeVar.NOALIAS(), DAE.emptyElementSource, SimCodeVar.NONECAUS(), NONE(), {}, false, isProtected);
    then
      createAllDiffedSimVars(restVar, cref, inAllVars, inIndex+1, inMatrixName, r1::iVars);

     case(BackendDAE.VAR(varName=currVar, varKind=BackendDAE.STATE(), values = dae_var_attr)::restVar, cref, _, _, _, _) equation
      currVar = ComponentReference.crefPrefixDer(currVar);
      derivedCref = Differentiate.differentiateVarWithRespectToX(currVar, cref, inMatrixName);
      isProtected = getProtected(dae_var_attr);
      r1 = SimCodeVar.SIMVAR(derivedCref, BackendDAE.VARIABLE(), "", "", "", -1, NONE(), NONE(), NONE(), NONE(), false, DAE.T_REAL_DEFAULT, false, NONE(), SimCodeVar.NOALIAS(), DAE.emptyElementSource, SimCodeVar.NONECAUS(), NONE(), {}, false, isProtected);
    then
      createAllDiffedSimVars(restVar, cref, inAllVars, inIndex, inMatrixName, r1::iVars);

    case(BackendDAE.VAR(varName=currVar, values = dae_var_attr)::restVar, cref, _, _, _, _) equation
      derivedCref = Differentiate.differentiateVarWithRespectToX(currVar, cref, inMatrixName);
      isProtected = getProtected(dae_var_attr);
      r1 = SimCodeVar.SIMVAR(derivedCref, BackendDAE.VARIABLE(), "", "", "", -1, NONE(), NONE(), NONE(), NONE(), false, DAE.T_REAL_DEFAULT, false, NONE(), SimCodeVar.NOALIAS(), DAE.emptyElementSource, SimCodeVar.NONECAUS(), NONE(), {}, false, isProtected);
    then
      createAllDiffedSimVars(restVar, cref, inAllVars, inIndex, inMatrixName, r1::iVars);

    else
     equation
      Error.addMessage(Error.INTERNAL_ERROR, {"function createAllDiffedSimVars failed"});
    then fail();
  end matchcontinue;
end createAllDiffedSimVars;

protected function addLinearizationMatrixes
"fuction creates the jacobian column-wise
 author: wbraun"
  input list<SimCode.JacobianMatrix> injacobianMatrixes;
  output list<SimCode.JacobianMatrix> outjacobianMatrixes;
algorithm
  outjacobianMatrixes :=
  matchcontinue (injacobianMatrixes)
    local
      SimCode.JacobianMatrix inSymJacs;
    case (inSymJacs::{})
      equation
        outjacobianMatrixes = {inSymJacs, ({}, {}, "B", ({}, {}, ({}, {})), {}, 0, -1), ({}, {}, "C", ({}, {}, ({}, {})), {}, 0, -1), ({}, {}, "D", ({}, {}, ({}, {})), {}, 0, -1)};
      then
        outjacobianMatrixes;
    case _
      equation
        true = (4 == listLength(injacobianMatrixes));
      then
        injacobianMatrixes;
    else {({}, {}, "A", ({}, {}, ({}, {})), {}, 0, -1), ({}, {}, "B", ({}, {}, ({}, {})), {}, 0, -1), ({}, {}, "C", ({}, {}, ({}, {})), {}, 0, -1), ({}, {}, "D", ({}, {}, ({}, {})), {}, 0, -1)};
  end matchcontinue;
end addLinearizationMatrixes;

protected function collectAllJacobianEquations
  input list<SimCode.JacobianMatrix> inJacobianMatrix;
  input list<SimCode.SimEqSystem> inAccum;
  output list<SimCode.SimEqSystem> outEqn;
algorithm
  outEqn :=
  match(inJacobianMatrix, inAccum)
      local
        list<SimCode.JacobianColumn> column;
        list<SimCode.SimEqSystem> tmp, tmp1;
        list<SimCode.JacobianMatrix> rest;
    case ({},_) then inAccum;

    case ((column, _, _, _, _, _, _)::rest, _)
      equation
        tmp = appendAllequation(column, {});
        tmp1 = listAppend(tmp, inAccum);
        tmp1 = collectAllJacobianEquations(rest, tmp1);
      then tmp1;
end match;
end collectAllJacobianEquations;

protected function appendAllequation
  input list<SimCode.JacobianColumn> inJacobianColumn;
  input list<SimCode.SimEqSystem> inAccum;
  output list<SimCode.SimEqSystem> outEqn;
algorithm
  outEqn :=
  match(inJacobianColumn, inAccum)
      local
        list<SimCode.SimEqSystem> tmp, tmp1;
        list<SimCode.JacobianColumn> rest;
    case ({}, _) then inAccum;

    case (((tmp, _, _)::rest), _)
      equation
        tmp1 = listAppend(tmp, inAccum);
        tmp1 = appendAllequation(rest, tmp1);
      then tmp1;
end match;
end appendAllequation;

protected function collectAllJacobianVars
  input list<SimCode.JacobianMatrix> inJacobianMatrix;
  input list<SimCodeVar.SimVar> inAccum;
  output list<SimCodeVar.SimVar> outEqn;
algorithm
  outEqn :=
  match(inJacobianMatrix, inAccum)
      local
        list<SimCode.JacobianColumn> column;
        list<SimCodeVar.SimVar> tmp, tmp1;
        list<SimCode.JacobianMatrix> rest;
    case ({},_) then inAccum;

    case ((column, _, _, _, _, _, _)::rest, _)
      equation
        tmp = appendAllVars(column, {});
        tmp1 = listAppend(tmp, inAccum);
        tmp1 = collectAllJacobianVars(rest, tmp1);
      then tmp1;
end match;
end collectAllJacobianVars;

protected function appendAllVars
  input list<SimCode.JacobianColumn> inJacobianColumn;
  input list<SimCodeVar.SimVar> inAccum;
  output list<SimCodeVar.SimVar> outEqn;
algorithm
  outEqn :=
  match(inJacobianColumn, inAccum)
      local
        list<SimCodeVar.SimVar> tmp, tmp1;
        list<SimCode.JacobianColumn> rest;
    case ({}, _) then inAccum;

    case (((_, tmp, _)::rest), _)
      equation
        tmp1 = listAppend(tmp, inAccum);
        tmp1 = appendAllVars(rest, tmp1);
      then tmp1;
end match;
end appendAllVars;

// =============================================================================
// section with unsorted function
//
// TODO: clean up this section ;)
// =============================================================================

protected function isSimEqSys  "checks if the given SES needs an additional equationsystem for the simulation and therefore skips an simEqIdx in the c-file.
this is used to get the right simCode-eq-mapping for hpcm.
add more cases here if you know for which cases this happens.
author: Waurich TUD 2013-11 "
  input SimCode.SimEqSystem simEqSysIn;
  output Boolean isEqSys;
algorithm
  isEqSys := match(simEqSysIn)
  case(SimCode.SES_NONLINEAR())
    then true;
  else
    then false;
  end match;
end isSimEqSys;

protected function collectDelayExpressions
"Put expression into a list if it is a call to delay().
Useable as a function parameter for Expression.traverseExpression."
  input DAE.Exp e;
  input list<DAE.Exp> acc;
  output DAE.Exp outExp;
  output list<DAE.Exp> outAcc;
algorithm
  (outExp,outAcc) := match (e,acc)
    case (DAE.CALL(path = Absyn.IDENT("delay")), _)
      then (e, e :: acc);
    else (e,acc);
  end match;
end collectDelayExpressions;

protected function extractDelayedExpressions
  input BackendDAE.BackendDAE dlow;
  output list<tuple<Integer, tuple<DAE.Exp, DAE.Exp, DAE.Exp>>> delayedExps;
  output Integer maxDelayedExpIndex;
algorithm
  (delayedExps, maxDelayedExpIndex) := matchcontinue(dlow)
    local
      list<DAE.Exp> exps;
    case _
      equation
        ((_,exps)) = BackendDAEUtil.traverseBackendDAEExps(dlow, Expression.traverseSubexpressionsHelper, (collectDelayExpressions, {}));
        delayedExps = List.map(exps, extractIdAndExpFromDelayExp);
        maxDelayedExpIndex = List.fold(List.map(delayedExps, Util.tuple21), intMax, -1);
      then
        (delayedExps, maxDelayedExpIndex+1);
    else
      equation
        Error.addMessage(Error.INTERNAL_ERROR, {"function extractDelayedExpressions failed"});
      then
        fail();
  end matchcontinue;
end extractDelayedExpressions;

function extractIdAndExpFromDelayExp
  input DAE.Exp delayCallExp;
  output tuple<Integer, tuple<DAE.Exp, DAE.Exp, DAE.Exp>> delayedExp;
algorithm
  delayedExp :=
  match (delayCallExp)
    local
      DAE.Exp  e, delay, delayMax;
      Integer i;
    case (DAE.CALL(path=Absyn.IDENT("delay"), expLst={DAE.ICONST(i), e, delay, delayMax}))
    then ((i, (e, delay, delayMax)));
  end match;
end extractIdAndExpFromDelayExp;

public function createMakefileParams
  input list<String> includes;
  input list<String> libs;
  input list<String> libPaths;
  input Boolean isFunction;
  output SimCode.MakefileParams makefileParams;
protected
  String omhome, ccompiler, cxxcompiler, linker, exeext, dllext, cflags, ldflags, rtlibs, platform, fopenmp,compileDir;
algorithm
  ccompiler   := if stringEq(Config.simCodeTarget(),"JavaScript") then "emcc" else
                 (if Flags.isSet(Flags.HPCOM) then System.getOMPCCompiler() else System.getCCompiler());
  cxxcompiler := if stringEq(Config.simCodeTarget(),"JavaScript") then "emcc" else System.getCXXCompiler();
  linker := if stringEq(Config.simCodeTarget(),"JavaScript") then "emcc" else System.getLinker();
  exeext := if stringEq(Config.simCodeTarget(),"JavaScript") then ".js" else System.getExeExt();
  dllext := System.getDllExt();
  omhome := Settings.getInstallationDirectoryPath();
  omhome := System.trim(omhome, "\""); // Remove any quotation marks from omhome.
  cflags := System.getCFlags() + " " +
            (if Flags.isSet(Flags.HPCOM) then "-fopenmp" else "");
  cflags := if stringEq(Config.simCodeTarget(),"JavaScript") then "-Os -Wno-warn-absolute-paths" else cflags;
  ldflags := System.getLDFlags();
  rtlibs := if isFunction then System.getRTLibs() else System.getRTLibsSim();
  platform := System.modelicaPlatform();
  compileDir :=  System.pwd() + System.pathDelimiter();
  makefileParams := SimCode.MAKEFILE_PARAMS(ccompiler, cxxcompiler, linker, exeext, dllext,
        omhome, cflags, ldflags, rtlibs, includes, libs,libPaths, platform,compileDir);
end createMakefileParams;

protected function elaborateRecordDeclarationsFromTypes
  input list<DAE.Type> inTypes;
  input list<SimCode.RecordDeclaration> inAccRecordDecls;
  input list<String> inReturnTypes;
  output list<SimCode.RecordDeclaration> outRecordDecls;
  output list<String> outReturnTypes;
algorithm
  (outRecordDecls, outReturnTypes) :=
  match (inTypes, inAccRecordDecls, inReturnTypes)
    local
      list<SimCode.RecordDeclaration> accRecDecls;
      DAE.Type firstType;
      list<DAE.Type> restTypes;
      list<String> returnTypes;

    case ({}, accRecDecls, _)
    then (accRecDecls, inReturnTypes);
    case (firstType :: restTypes, accRecDecls, _)
      equation
        (accRecDecls, returnTypes) =
        elaborateRecordDeclarationsForRecord(firstType, accRecDecls, inReturnTypes);
        (accRecDecls, returnTypes) =
        elaborateRecordDeclarationsFromTypes(restTypes, accRecDecls, returnTypes);
      then (accRecDecls, returnTypes);
  end match;
end elaborateRecordDeclarationsFromTypes;

protected function elaborateRecordDeclarations
"Translate all records used by varlist to structs."
  input list<DAE.Element> inVars;
  input list<SimCode.RecordDeclaration> inAccRecordDecls;
  input list<String> inReturnTypes;
  output list<SimCode.RecordDeclaration> outRecordDecls;
  output list<String> outReturnTypes;
algorithm
  (outRecordDecls, outReturnTypes) :=
  matchcontinue (inVars, inAccRecordDecls, inReturnTypes)
    local
      DAE.Element var;
      list<DAE.Element> rest;
      DAE.Type ft;
      list<String> rt, rt_1, rt_2;
      list<SimCode.RecordDeclaration> accRecDecls;
      DAE.Algorithm algorithm_;
      list<DAE.Exp> expl;

    case ({}, accRecDecls, rt) then (accRecDecls, rt);

    case (((DAE.VAR(ty = ft)) :: rest), accRecDecls, rt)
      equation
        (accRecDecls, rt_1) = elaborateRecordDeclarationsForRecord(ft, accRecDecls, rt);
        (accRecDecls, rt_2) = elaborateRecordDeclarations(rest, accRecDecls, rt_1);
      then
        (accRecDecls, rt_2);

    case ((DAE.ALGORITHM(algorithm_ = algorithm_) :: rest), accRecDecls, rt)
      equation
        true = Config.acceptMetaModelicaGrammar();
        ((_, expl)) = BackendDAEUtil.traverseAlgorithmExps(algorithm_, Expression.traverseSubexpressionsHelper, (matchMetarecordCalls, {}));
        (accRecDecls, rt_2) = elaborateRecordDeclarationsForMetarecords(expl, accRecDecls, rt);
        // TODO: ? what about rest ? , can be there something else after the ALGORITHM
        (accRecDecls, rt_2) = elaborateRecordDeclarations(rest, accRecDecls, rt_2);
      then
        (accRecDecls, rt_2);

    case ((_ :: rest), accRecDecls, rt)
      equation
        (accRecDecls, rt_1) = elaborateRecordDeclarations(rest, accRecDecls, rt);
      then
        (accRecDecls, rt_1);
  end matchcontinue;
end elaborateRecordDeclarations;

protected function elaborateRecordDeclarationsForRecord
"Helper function to generateStructsForRecords."
  input DAE.Type inRecordType;
  input list<SimCode.RecordDeclaration> inAccRecordDecls;
  input list<String> inReturnTypes;
  output list<SimCode.RecordDeclaration> outRecordDecls;
  output list<String> outReturnTypes;
algorithm
  (outRecordDecls, outReturnTypes) := match (inRecordType, inAccRecordDecls, inReturnTypes)
    local
      Absyn.Path path, name;
      list<DAE.Var> varlst;
      String    sname;
      list<String> rt, rt_1, rt_2, fieldNames;
      list<SimCode.RecordDeclaration> accRecDecls;
      list<SimCode.Variable> vars;
      Integer index;
      SimCode.RecordDeclaration recDecl;

    case (DAE.T_COMPLEX(complexClassType = ClassInf.RECORD(name), varLst = varlst, source = {_}), accRecDecls, rt)
      equation
        sname = Absyn.pathStringUnquoteReplaceDot(name, "_");
        if not listMember(sname, rt) then
          vars = List.map(varlst, typesVarNoBinding);
          vars = List.sort(vars,compareVariable);
          rt_1 = sname :: rt;
          (accRecDecls, rt_2) = elaborateNestedRecordDeclarations(varlst, accRecDecls, rt_1);
          recDecl = SimCode.RECORD_DECL_FULL(sname, NONE(), name, vars);
          accRecDecls = List.appendElt(recDecl, accRecDecls);
        else
          rt_2 = rt;
        end if;
      then (accRecDecls, rt_2);

    case (DAE.T_COMPLEX(complexClassType = ClassInf.RECORD(_)), accRecDecls, rt)
    then (accRecDecls, rt);

    case (DAE.T_METARECORD(source = {Absyn.QUALIFIED(name="SourceInfo")}), accRecDecls, rt)
      then (accRecDecls, rt);

    case (DAE.T_METARECORD( fields = varlst, source = {path}), accRecDecls, rt)
      equation
        sname = Absyn.pathStringUnquoteReplaceDot(path, "_");
        if not listMember(sname, rt) then
          fieldNames = List.map(varlst, generateVarName);
          accRecDecls = SimCode.RECORD_DECL_DEF(path, fieldNames) :: accRecDecls;
          rt_1 = sname::rt;
          (accRecDecls, rt_2) = elaborateNestedRecordDeclarations(varlst, accRecDecls, rt_1);
        else
          rt_2 = rt;
        end if;
      then (accRecDecls, rt_2);

    case (_, accRecDecls, rt)
    then (accRecDecls, rt);

  end match;
end elaborateRecordDeclarationsForRecord;

protected function generateVarName
  input DAE.Var inVar;
  output String outName;
algorithm
  outName :=
  matchcontinue (inVar)
    local
      DAE.Ident name;
    case DAE.TYPES_VAR(name = name)
    then name;
    case (_)
    then "NULL";
  end matchcontinue;
end generateVarName;

protected function elaborateNestedRecordDeclarations
"Helper function to elaborateRecordDeclarations."
  input list<DAE.Var> inRecordTypes;
  input list<SimCode.RecordDeclaration> inAccRecordDecls;
  input list<String> inReturnTypes;
  output list<SimCode.RecordDeclaration> outRecordDecls;
  output list<String> outReturnTypes;
algorithm
  (outRecordDecls, outReturnTypes) := matchcontinue (inRecordTypes, inAccRecordDecls, inReturnTypes)
    local
      DAE.Type ty;
      list<DAE.Var> rest;
      list<String> rt, rt_1, rt_2;
      list<SimCode.RecordDeclaration> accRecDecls;
    case ({}, accRecDecls, rt)
    then (accRecDecls, rt);
    case (DAE.TYPES_VAR(ty = ty as DAE.T_COMPLEX(complexClassType = ClassInf.RECORD(_)))::rest, accRecDecls, rt)
      equation
        (accRecDecls, rt_1) = elaborateRecordDeclarationsForRecord(ty, accRecDecls, rt);
        (accRecDecls, rt_2) = elaborateNestedRecordDeclarations(rest, accRecDecls, rt_1);
      then (accRecDecls, rt_2);
    case (_::rest, accRecDecls, rt)
      equation
        (accRecDecls, rt_1) = elaborateNestedRecordDeclarations(rest, accRecDecls, rt);
      then (accRecDecls, rt_1);
  end matchcontinue;
end elaborateNestedRecordDeclarations;

protected function elaborateRecordDeclarationsForMetarecords
  input list<DAE.Exp> inExpl;
  input list<SimCode.RecordDeclaration> inAccRecordDecls;
  input list<String> inReturnTypes;
  output list<SimCode.RecordDeclaration> outRecordDecls;
  output list<String> outReturnTypes;
algorithm
  (outRecordDecls, outReturnTypes) := match (inExpl, inAccRecordDecls, inReturnTypes)
    local
      list<String> rt, rt_1, rt_2, fieldNames;
      list<DAE.Exp> rest;
      String name;
      Absyn.Path path;
      list<SimCode.RecordDeclaration> accRecDecls;
      Boolean b;

    case ({}, accRecDecls, rt) then (accRecDecls, rt);
    case (DAE.METARECORDCALL(path=path, fieldNames=fieldNames)::rest, accRecDecls, rt)
      equation
        name = Absyn.pathStringUnquoteReplaceDot(path, "_");
        b = listMember(name, rt);
        accRecDecls = List.consOnTrue(not b, SimCode.RECORD_DECL_DEF(path, fieldNames), accRecDecls);
        rt_1 = List.consOnTrue(not b, name, rt);
        (accRecDecls, rt_2) = elaborateRecordDeclarationsForMetarecords(rest, accRecDecls, rt_1);
      then (accRecDecls, rt_2);
   case (_::rest, accRecDecls, rt)
     equation
       (accRecDecls, rt_1) = elaborateRecordDeclarationsForMetarecords(rest, accRecDecls, rt);
     then (accRecDecls, rt_1);
  end match;
end elaborateRecordDeclarationsForMetarecords;

protected function createExtObjInfo
  input BackendDAE.Shared shared;
  output SimCode.ExtObjInfo extObjInfo;
protected
  BackendDAE.Variables evars;
  list<BackendDAE.Var> evarLst;
  list<SimCode.ExtAlias> aliases;
  list<SimCodeVar.SimVar> simvars;
algorithm
  BackendDAE.SHARED(externalObjects=evars) := shared;
  evarLst := BackendVariable.varList(evars);
  evarLst := listReverse(evarLst);
  (simvars, aliases) := extractExtObjInfo2(evarLst, evars, {}, {});
  extObjInfo := SimCode.EXTOBJINFO(simvars, aliases);
end createExtObjInfo;

protected function extractExtObjInfo2
  input list<BackendDAE.Var> varLst;
  input BackendDAE.Variables evars;
  input list<SimCodeVar.SimVar> ivars;
  input list<SimCode.ExtAlias> ialiases;
  output list<SimCodeVar.SimVar> vars;
  output list<SimCode.ExtAlias> aliases;
algorithm
  (vars, aliases) := match (varLst, evars, ivars, ialiases)
    local
      BackendDAE.Var bv;
      SimCodeVar.SimVar sv;
      list<BackendDAE.Var> vs;
      DAE.ComponentRef cr, name;
    case ({}, _, _, _) then (listReverse(ivars), listReverse(ialiases));
    case (BackendDAE.VAR(varName=name, bindExp=SOME(DAE.CREF(cr, _)), varKind=BackendDAE.EXTOBJ(_))::vs, _, _, _)
      equation
        (vars, aliases) = extractExtObjInfo2(vs, evars, ivars, (name, cr)::ialiases);
      then (vars, aliases);
    case (bv::vs, _, _, _)
      equation
        sv = dlowvarToSimvar(bv, NONE(), evars);
        (vars, aliases) = extractExtObjInfo2(vs, evars, sv::ivars, ialiases);
      then (vars, aliases);
  end match;
end extractExtObjInfo2;

protected function createAlgorithmAndEquationAsserts
  input BackendDAE.EqSystem syst;
  input BackendDAE.Shared shared;
  input tuple<Integer, list<SimCode.SimEqSystem>> acc;
  output tuple<Integer, list<SimCode.SimEqSystem>> algorithmAndEquationAsserts;
algorithm
  algorithmAndEquationAsserts := matchcontinue (syst, shared, acc)
    local
      list<SimCode.SimEqSystem> simeqns;
      list<DAE.Algorithm> res;
      BackendDAE.EquationArray eqns, reqns;
      BackendDAE.Variables vars;
      list<SimCode.SimEqSystem> result;
      Integer uniqueEqIndex;

    case (BackendDAE.EQSYSTEM(orderedVars = vars), BackendDAE.SHARED(), (uniqueEqIndex, simeqns))
      equation
        // get minmax and nominal asserts
        res = BackendVariable.traverseBackendDAEVars(vars, createVarMinMaxAssert, {});
        (result, uniqueEqIndex) = List.mapFold(res, dlowAlgToSimEqSystem, uniqueEqIndex);
        result = listAppend(result, simeqns);
      then ((uniqueEqIndex, result));
    else
      equation
        Error.addMessage(Error.INTERNAL_ERROR, {"function createAlgorithmAndEquationAsserts failed"});
      then fail();
  end matchcontinue;
end createAlgorithmAndEquationAsserts;

protected function createRemovedEquations
  input BackendDAE.EqSystem syst;
  input BackendDAE.Shared shared;
  input list<SimCode.SimEqSystem> acc;
  output list<SimCode.SimEqSystem> removedEquations;
algorithm
  removedEquations := matchcontinue (syst, shared, acc)
    local
      BackendDAE.EquationArray r;
      BackendDAE.Variables vars;
      list<DAE.Algorithm> varasserts;
      list<SimCode.SimEqSystem> simvarasserts;

    case (BackendDAE.EQSYSTEM(orderedVars = vars), BackendDAE.SHARED(), _)
      equation
        // get minmax and nominal asserts
        varasserts = BackendVariable.traverseBackendDAEVars(vars, createVarMinMaxAssert, {});
        (simvarasserts, _) = List.mapFold(varasserts, dlowAlgToSimEqSystem, 0);
        removedEquations = listAppend(simvarasserts, acc);
      then removedEquations;
    else
      equation
        Error.addMessage(Error.INTERNAL_ERROR, {"function createRemovedEquations failed"});
      then fail();
  end matchcontinue;
end createRemovedEquations;

protected function traversedlowEqToSimEqSystem
  input BackendDAE.Equation inEq;
  input tuple<Integer, list<SimCode.SimEqSystem>> inTpl;
  output BackendDAE.Equation outEq;
  output tuple<Integer, list<SimCode.SimEqSystem>> outTpl;
algorithm
  (outEq,outTpl) := matchcontinue (inEq,inTpl)
    local
      BackendDAE.Equation e;
      SimCode.SimEqSystem se;
      list<SimCode.SimEqSystem> seqnlst;
      Integer uniqueEqIndex;
    case (e, (uniqueEqIndex, seqnlst))
      equation
        (se, uniqueEqIndex) = dlowEqToSimEqSystem(e, uniqueEqIndex);
      then (e, (uniqueEqIndex, se::seqnlst));
    else (inEq,inTpl);
  end matchcontinue;
end traversedlowEqToSimEqSystem;

protected function extractDiscreteModelVars
  input BackendDAE.EqSystem syst;
  input BackendDAE.Shared shared;
  input list<DAE.ComponentRef> acc;
  output list<DAE.ComponentRef> discreteModelVars;
algorithm
  discreteModelVars := matchcontinue (syst, shared, acc)
    local
      BackendDAE.Variables v;
      BackendDAE.EquationArray e;
      list<DAE.ComponentRef> vLst2;

    case (BackendDAE.EQSYSTEM(orderedVars=v), _, _)
      equation
        // select all discrete vars.
        // remove those vars that are solved in when equations
        // replace var with cref
        vLst2 = BackendVariable.traverseBackendDAEVars(v, traversingisVarDiscreteCrefFinder, {});
        vLst2 = listAppend(vLst2, acc);
        // vLst2 = List.unionOnTrue(vLst2, vLst1, ComponentReference.crefEqual);
      then vLst2;
    else
      equation
        Error.addMessage(Error.INTERNAL_ERROR, {"function extractDiscreteModelVars failed"});
      then fail();
  end matchcontinue;
end extractDiscreteModelVars;

protected function traversingisVarDiscreteCrefFinder
  input BackendDAE.Var inVar;
  input list<DAE.ComponentRef> inTpl;
  output BackendDAE.Var outVar;
  output list<DAE.ComponentRef> outTpl;
algorithm
  (outVar,outTpl) := matchcontinue (inVar,inTpl)
    local
      BackendDAE.Var v;
      list<DAE.ComponentRef> cr_lst;
      DAE.ComponentRef cr;
    case (v, cr_lst)
      equation
        true = BackendDAEUtil.isVarDiscrete(v);
        cr = BackendVariable.varCref(v);
      then (v, cr::cr_lst);
    else (inVar,inTpl);
  end matchcontinue;
end traversingisVarDiscreteCrefFinder;

protected function jacToSimjac
  input tuple<Integer, Integer, BackendDAE.Equation> jac;
  input BackendDAE.Variables v;
  output tuple<Integer, Integer, SimCode.SimEqSystem> simJac;
algorithm
  simJac := match (jac, v)
    local
      Integer row;
      Integer col;
      DAE.Exp e;
      DAE.ElementSource source;

    case ((row, col, BackendDAE.RESIDUAL_EQUATION(exp=e, source=source)), _)
      equation
        // rhs_exp = BackendDAEUtil.getEqnsysRhsExp(e, v, NONE());
        // rhs_exp_1 = ExpressionSimplify.simplify(rhs_exp);
        // then ((row - 1, col - 1, SimCode.SES_RESIDUAL(rhs_exp_1)));
      then
        ((row - 1, col - 1, SimCode.SES_RESIDUAL(0, e, source)));
  end match;
end jacToSimjac;

protected function createSingleWhenEqnCode
  input BackendDAE.Equation inEquation;
  input list<BackendDAE.Var> inVars;
  input BackendDAE.Shared shared;
  input Integer iuniqueEqIndex;
  input list<SimCodeVar.SimVar> itempvars;
  output list<SimCode.SimEqSystem> equations_;
  output Integer ouniqueEqIndex;
  output list<SimCodeVar.SimVar> otempvars;
algorithm
  (equations_, ouniqueEqIndex, otempvars) := matchcontinue(inEquation, inVars, shared, iuniqueEqIndex, itempvars)
    local
      DAE.Exp cond, right;
      DAE.ComponentRef left;
      DAE.ElementSource source;
      list<DAE.ComponentRef> crefs;
      BackendDAE.WhenEquation elseWhen;
      list<DAE.ComponentRef> conditions;
      list<BackendDAE.WhenClause> wcl;
      SimCode.SimEqSystem elseWhenEquation;
      Boolean initialCall;

    // when eq without else
    case (BackendDAE.WHEN_EQUATION(whenEquation=BackendDAE.WHEN_EQ(cond, left, right, NONE()), source=source), _, _, _, _)
      equation
        crefs = List.map(inVars, BackendVariable.varCref);
        List.map1rAllValue(crefs, ComponentReference.crefPrefixOf, true, left);
        (conditions, initialCall) = BackendDAEUtil.getConditionList(cond);
      then ({SimCode.SES_WHEN(iuniqueEqIndex, conditions, initialCall, left, right, NONE(), source)}, iuniqueEqIndex+1, itempvars);

    // when eq with else
    case (BackendDAE.WHEN_EQUATION(whenEquation=BackendDAE.WHEN_EQ(cond, left, right, SOME(elseWhen)), source=source), _, BackendDAE.SHARED(eventInfo=BackendDAE.EVENT_INFO(whenClauseLst=wcl)), _, _)
      equation
        crefs = List.map(inVars, BackendVariable.varCref);
        List.map1rAllValue(crefs, ComponentReference.crefPrefixOf, true, left);
        elseWhenEquation = createElseWhenEquation(elseWhen, wcl, source);
        (conditions, initialCall) = BackendDAEUtil.getConditionList(cond);
      then ({SimCode.SES_WHEN(iuniqueEqIndex, conditions, initialCall, left, right, SOME(elseWhenEquation), source)}, iuniqueEqIndex+1, itempvars);

    // failure
    else
      equation
        Error.addMessage(Error.INTERNAL_ERROR, {"function createSingleWhenEqnCode failed. When equations currently only supported on form v = ..."});
      then fail();
  end matchcontinue;
end createSingleWhenEqnCode;

protected function createElseWhenEquation
  input BackendDAE.WhenEquation inElseWhenEquation;
  input list<BackendDAE.WhenClause> inWhenClause;
  input DAE.ElementSource inElementSource;
  output SimCode.SimEqSystem outSimEqSystem;
algorithm
  outSimEqSystem := match (inElseWhenEquation, inWhenClause, inElementSource)
    local
      DAE.ComponentRef left;
      DAE.Exp right, cond;
      BackendDAE.WhenEquation elseWhenEquation;
      SimCode.SimEqSystem simElseWhenEq;
      list<DAE.ComponentRef> conditions;
      Boolean initialCall;

    // when eq without else
    case (BackendDAE.WHEN_EQ(condition=cond, left=left, right=right, elsewhenPart= NONE()), _, _) equation
      (conditions, initialCall) = BackendDAEUtil.getConditionList(cond);
    then SimCode.SES_WHEN(0, conditions, initialCall, left, right, NONE(), inElementSource);

    // when eq with else
    case (BackendDAE.WHEN_EQ(condition=cond, left=left, right=right, elsewhenPart = SOME(elseWhenEquation)), _, _) equation
      simElseWhenEq = createElseWhenEquation(elseWhenEquation, inWhenClause, inElementSource);
      (conditions, initialCall) = BackendDAEUtil.getConditionList(cond);
    then SimCode.SES_WHEN(0, conditions, initialCall, left, right, SOME(simElseWhenEq), inElementSource);
  end match;
end createElseWhenEquation;

protected function createSingleIfEqnCode
  input BackendDAE.Equation inEquation;
  input list<BackendDAE.Var> inVars;
  input BackendDAE.Shared shared;
  input Boolean genDiscrete;
  input Integer iuniqueEqIndex;
  input list<SimCodeVar.SimVar> itempvars;
  output list<SimCode.SimEqSystem> equations_;
  output Integer ouniqueEqIndex;
  output list<SimCodeVar.SimVar> otempvars;
algorithm
  (equations_, ouniqueEqIndex, otempvars) := matchcontinue(inEquation, inVars, shared, genDiscrete, iuniqueEqIndex, itempvars)
    local
      list<DAE.Exp> conditions;
      Integer uniqueEqIndex;

      list<SimCodeVar.SimVar> tempvars;
      list<list<BackendDAE.Equation>> eqnsLst;
      list<BackendDAE.Equation> elseqns;
      list<tuple<DAE.Exp, list<SimCode.SimEqSystem>>> ifbranches;
      DAE.ElementSource source_;
      BackendDAE.ExtraInfo ei;

    case (BackendDAE.IF_EQUATION(conditions=conditions, eqnstrue=eqnsLst, eqnsfalse=elseqns, source=source_), _,
          BackendDAE.SHARED(info = ei), _, _, _) equation
      (ifbranches, uniqueEqIndex, tempvars) = createEquationsIfBranch(conditions, eqnsLst, inVars, shared, genDiscrete, iuniqueEqIndex, itempvars);
      (equations_, uniqueEqIndex, tempvars) = createEquationsfromList(elseqns, inVars, genDiscrete, uniqueEqIndex, tempvars, ei);
    then ({SimCode.SES_IFEQUATION(uniqueEqIndex, ifbranches, equations_, source_)}, uniqueEqIndex+1, tempvars);

    else equation
      Error.addMessage(Error.INTERNAL_ERROR, {"SimCodeUtil.createSingleIfEqnCode failed."});
    then fail();
  end matchcontinue;
end createSingleIfEqnCode;

protected function createEquationsIfBranch
  input list<DAE.Exp> inConditions;
  input list<list<BackendDAE.Equation>> inEquationsLst;
  input list<BackendDAE.Var> inVars;
  input BackendDAE.Shared shared;
  input Boolean genDiscrete;
  input Integer iuniqueEqIndex;
  input list<SimCodeVar.SimVar> itempvars;
  output list<tuple<DAE.Exp, list<SimCode.SimEqSystem>>> outEquations;
  output Integer ouniqueEqIndex;
  output list<SimCodeVar.SimVar> otempvars;
algorithm
  (outEquations, ouniqueEqIndex, otempvars) := matchcontinue(inConditions, inEquationsLst, inVars, shared, genDiscrete, iuniqueEqIndex, itempvars)
    local
      list<BackendDAE.Equation> eqns;
      list<list<BackendDAE.Equation>> eqnsLst;
      DAE.Exp  condition;
      list<DAE.Exp>  conditionList;
      list<SimCodeVar.SimVar> tempvars;
      Integer uniqueEqIndex;
      list<SimCode.SimEqSystem> equations_;
      tuple<DAE.Exp, list<SimCode.SimEqSystem>> ifbranch;
      list<tuple<DAE.Exp, list<SimCode.SimEqSystem>>> ifbranches;
      BackendDAE.ExtraInfo ei;

    case ({}, {}, _, _, _, _, _)
    then ({}, iuniqueEqIndex, itempvars);

    case (condition::conditionList, eqns::eqnsLst, _,
          BackendDAE.SHARED(info = ei), _, _, _) equation
      (equations_, uniqueEqIndex, tempvars) = createEquationsfromList(eqns, inVars, genDiscrete, iuniqueEqIndex, itempvars, ei);
      ifbranch = ((condition, equations_));
      (ifbranches, uniqueEqIndex, tempvars) = createEquationsIfBranch(conditionList, eqnsLst, inVars, shared, genDiscrete, uniqueEqIndex, tempvars);
      ifbranches = listAppend({ifbranch}, ifbranches);
    then (ifbranches, uniqueEqIndex, tempvars);

    else equation
      Error.addMessage(Error.INTERNAL_ERROR, {"SimCodeUtil.createEquationfromList failed."});
    then fail();
  end matchcontinue;
end createEquationsIfBranch;

protected function createEquationsfromList
  input list<BackendDAE.Equation> inEquations;
  input list<BackendDAE.Var> inVars;
  input Boolean genDiscrete;
  input Integer iuniqueEqIndex;
  input list<SimCodeVar.SimVar> itempvars;
  input BackendDAE.ExtraInfo iextra;
  output list<SimCode.SimEqSystem> equations_;
  output Integer ouniqueEqIndex;
  output list<SimCodeVar.SimVar> otempvars;
algorithm
  (equations_, ouniqueEqIndex, otempvars) := matchcontinue(inEquations, inVars, genDiscrete, iuniqueEqIndex, itempvars, iextra)
    local
      BackendDAE.Variables evars, vars1;
      BackendDAE.EquationArray eeqns, eqns_1;
      FCore.Cache cache;
      FCore.Graph graph;
      DAE.FunctionTree funcs;
      BackendDAE.BackendDAE subsystem_dae;
      BackendDAE.StrongComponents comps;
      BackendDAE.EqSystem syst;
      BackendDAE.Shared shared;
      Integer uniqueEqIndex;
      list<SimCodeVar.SimVar> tempvars;

    case ({}, _, _, _, _, _)
    then ({}, iuniqueEqIndex, itempvars);

    case (_, _, _, _, _, _) equation
      eqns_1 = BackendEquation.listEquation(inEquations);
      vars1 = BackendVariable.listVar1(inVars);
      evars = BackendVariable.emptyVars();
      eeqns = BackendEquation.emptyEqns();
      cache = FCore.emptyCache();
      graph = FGraph.empty();
      funcs = DAEUtil.avlTreeNew();
      syst = BackendDAE.EQSYSTEM(vars1, eqns_1, NONE(), NONE(), BackendDAE.NO_MATCHING(), {}, BackendDAE.UNKNOWN_PARTITION());
      shared = BackendDAE.SHARED(evars, evars, evars, eeqns, eeqns, {}, {}, cache, graph, funcs, BackendDAE.EVENT_INFO({}, {}, {}, {}, {}, 0), {}, BackendDAE.ARRAYSYSTEM(), {}, iextra);
      subsystem_dae = BackendDAE.DAE({syst}, shared);
      (BackendDAE.DAE({syst as BackendDAE.EQSYSTEM(matching=BackendDAE.MATCHING(comps=comps))}, shared)) = BackendDAEUtil.transformBackendDAE(subsystem_dae, SOME((BackendDAE.NO_INDEX_REDUCTION(), BackendDAE.ALLOW_UNDERCONSTRAINED())), NONE(), NONE());
      (equations_, _, uniqueEqIndex, tempvars) = createEquations(false, false, genDiscrete, false, syst, shared, comps, iuniqueEqIndex, itempvars);
    then (equations_, uniqueEqIndex, tempvars);

    else equation
      Error.addMessage(Error.INTERNAL_ERROR, {"SimCodeUtil.createEquationfromList failed."});
    then fail();

  end matchcontinue;
end createEquationsfromList;

protected function createSingleComplexEqnCode
  input BackendDAE.Equation inEquation;
  input list<BackendDAE.Var> inVars;
  input Integer iuniqueEqIndex;
  input list<SimCodeVar.SimVar> itempvars;
  output list<SimCode.SimEqSystem> equations_;
  output Integer ouniqueEqIndex;
  output list<SimCodeVar.SimVar> otempvars;
algorithm
  (equations_, ouniqueEqIndex, otempvars) := matchcontinue(inEquation, inVars, iuniqueEqIndex, itempvars)
    local
      Integer uniqueEqIndex;
      DAE.Exp e1, e2;
      DAE.ElementSource source;
      list<DAE.ComponentRef> crefs;
      list<SimCode.SimEqSystem> resEqs;
      list<SimCodeVar.SimVar> tempvars;
      String s, s1, s2, s3;
      Boolean homotopySupport;

    case (BackendDAE.COMPLEX_EQUATION(left=e1, right=e2, source=source), _, _, _) equation
      crefs = List.map(inVars, BackendVariable.varCref);
      e1 = Expression.replaceDerOpInExp(e1);
      e2 = Expression.replaceDerOpInExp(e2);
      (equations_, uniqueEqIndex, tempvars) = createSingleComplexEqnCode2(crefs, e1, e2, iuniqueEqIndex, itempvars, source);
    then (equations_, uniqueEqIndex, tempvars);

    case (BackendDAE.COMPLEX_EQUATION(), _, _, _) equation
      crefs = List.map(inVars, BackendVariable.varCref);

      // check that all crefs are of Type Real
      // otherwise we can't solve that with one Non-linear equation
      true = Util.boolAndList(List.map(List.map(crefs, ComponentReference.crefLastType), Types.isRealOrSubTypeReal));

      // wbraun:
      // TODO: Fix createNonlinearResidualEquations support cases where
      //       solved variables are on rhs and also lhs. This is not
      //       cosidered yet there.
      (resEqs, uniqueEqIndex, tempvars) = createNonlinearResidualEquations({inEquation}, iuniqueEqIndex, itempvars);
      (_, homotopySupport) = BackendDAETransform.traverseExpsOfEquation(inEquation, containsHomotopyCall, false);
    then ({SimCode.SES_NONLINEAR(uniqueEqIndex, resEqs, crefs, 0, NONE(), false, homotopySupport, false)}, uniqueEqIndex+1, tempvars);

    // failure
    case (BackendDAE.COMPLEX_EQUATION(left=e1, right=e2), _, _, _) equation
      crefs = List.map(inVars, BackendVariable.varCref);

      // check that all crefs are of Type Real
      // otherwise we can't solve that with one Non-linear equation
      false = Util.boolAndList(List.map(List.map(crefs, ComponentReference.crefLastType), Types.isRealOrSubTypeReal));

      s1 = ExpressionDump.printExpStr(e1);
      s2 = ExpressionDump.printExpStr(e2);
      s3 = ComponentReference.printComponentRefListStr(crefs);
      s = stringAppendList({"No support of solving not real variables with a non-linear solver. Equation:\n", s1, " = " , s2, " solve for ", s3 });
      Error.addMessage(Error.INTERNAL_ERROR, {s});
    then fail();

    // failure
    case (BackendDAE.COMPLEX_EQUATION(left=e1, right=e2), _, _, _) equation
      crefs = List.map(inVars, BackendVariable.varCref);

      // check that all crefs are of Type Real
      // otherwise we can't solve that with one Non-linear equation
      true = Util.boolAndList(List.map(List.map(crefs, ComponentReference.crefLastType), Types.isRealOrSubTypeReal));

      s1 = ExpressionDump.printExpStr(e1);
      s2 = ExpressionDump.printExpStr(e2);
      s3 = ComponentReference.printComponentRefListStr(crefs);
      s = stringAppendList({"complex equations currently only supported on form v = functioncall(...). Equation: ", s1, " = " , s2, " solve for ", s3 });
      Error.addMessage(Error.INTERNAL_ERROR, {s});
    then fail();
  end matchcontinue;
end createSingleComplexEqnCode;

// TODO: are the cases really correct?
protected function createSingleComplexEqnCode2
  input list<DAE.ComponentRef> crefs;
  input DAE.Exp inExp3;
  input DAE.Exp inExp4;
  input Integer iuniqueEqIndex;
  input list<SimCodeVar.SimVar> itempvars;
  input DAE.ElementSource source;
  output list<SimCode.SimEqSystem> equations_;
  output Integer ouniqueEqIndex;
  output list<SimCodeVar.SimVar> otempvars;
algorithm
  (equations_, ouniqueEqIndex, otempvars) := matchcontinue (crefs, inExp3, inExp4, iuniqueEqIndex, itempvars, source)
    local
      DAE.ComponentRef cr1, cr2;
      DAE.Exp e1, e2, e1_1, e2_1;
      list<DAE.Exp> expl, expl1;
      DAE.Statement stms;
      DAE.Type tp;
      DAE.CallAttributes attr;
      Absyn.Path path, rpath;
      list<DAE.Exp> expLst, crexplst;
      DAE.Ident ident;
      list<tuple<DAE.Exp, DAE.Exp>> exptl;
      SimCode.SimEqSystem simeqn;
      list<SimCode.SimEqSystem> eqSystlst;
      list<SimCodeVar.SimVar> tempvars;
      Integer uniqueEqIndex;
      list<DAE.Var> varLst;
      HashSet.HashSet ht;
      list<Integer> positions;
      String s, s1, s2, s3;

    case (_, DAE.CAST(exp = e1), _, _, _, _)
      equation
        (equations_, ouniqueEqIndex, otempvars) =
          createSingleComplexEqnCode2(crefs, e1, inExp4, iuniqueEqIndex, itempvars, source);
      then
        (equations_, ouniqueEqIndex, otempvars);

    case (_, _, DAE.CAST(exp = e1), _, _, _)
      equation
        (equations_, ouniqueEqIndex, otempvars) =
          createSingleComplexEqnCode2(crefs, inExp3, e1, iuniqueEqIndex, itempvars, source);
      then
        (equations_, ouniqueEqIndex, otempvars);

    case (_, e1 as DAE.CREF(componentRef = cr2), e2, _, _, _)
      equation
        List.map1rAllValue(crefs, ComponentReference.crefPrefixOf, true, cr2);
        // ((e1_1, _)) = Expression.extendArrExp((e1, false));
        (e2_1, _) = Expression.extendArrExp(e2, false);
        // true = ComponentReference.crefEqualNoStringCompare(cr, cr2);
        tp = Expression.typeof(e1);
        stms = DAE.STMT_ASSIGN(tp, e1, e2_1, source);
      then
        ({SimCode.SES_ALGORITHM(iuniqueEqIndex, {stms})}, iuniqueEqIndex+1, itempvars);

    case (_, e1, e2 as DAE.CREF(componentRef = cr2), _, _, _)
      equation
        List.map1rAllValue(crefs, ComponentReference.crefPrefixOf, true, cr2);
        // true = ComponentReference.crefEqualNoStringCompare(cr, cr2);
        (e1_1, _) = Expression.extendArrExp(e1, false);
        // ((e2_1, _)) = Expression.extendArrExp((e2, false));
        tp = Expression.typeof(e2);
        stms = DAE.STMT_ASSIGN(tp, e2, e1_1, source);
      then
        ({SimCode.SES_ALGORITHM(iuniqueEqIndex, {stms})}, iuniqueEqIndex+1, itempvars);

    /* Record() = f()  */
    case (_, DAE.CALL(path=path, expLst=expLst, attr=DAE.CALL_ATTR(ty= tp as DAE.T_COMPLEX(complexClassType=ClassInf.RECORD(path=rpath), varLst=varLst))), e2, _, _, _)
      equation
        true = Absyn.pathEqual(path, rpath);
        ht = HashSet.emptyHashSet();
        ht = List.fold(crefs, BaseHashSet.add, ht);
        List.foldAllValue(expLst, createSingleComplexEqnCode3, true, ht);
        (e2_1, _) = Expression.extendArrExp(e2, false);
        // true = ComponentReference.crefEqualNoStringCompare(cr, cr2);
        // tmp = f()
        ident = Absyn.pathStringUnquoteReplaceDot(path, "_");
        cr1 = ComponentReference.makeCrefIdent("$TMP_" + ident + intString(iuniqueEqIndex), tp, {});
        e1_1 = Expression.crefExp(cr1);
        stms = DAE.STMT_ASSIGN(tp, e1_1, e2_1, source);
        simeqn = SimCode.SES_ALGORITHM(iuniqueEqIndex, {stms});
        uniqueEqIndex = iuniqueEqIndex + 1;
        // Record()=tmp
        crexplst = List.map1(varLst, Expression.generateCrefsExpFromExpVar, cr1);
        exptl = List.threadTuple(expLst, crexplst);
        (eqSystlst, uniqueEqIndex) = List.map1Fold(exptl, makeSES_SIMPLE_ASSIGN, source, uniqueEqIndex);
        eqSystlst = simeqn::eqSystlst;
        tempvars = createTempVars(varLst, cr1, itempvars);
      then
        (eqSystlst, uniqueEqIndex, tempvars);

    /* f() = Record()  */
    case (_, e1, DAE.CALL(path=path, expLst=expLst, attr=DAE.CALL_ATTR(ty= tp as DAE.T_COMPLEX(complexClassType=ClassInf.RECORD(path=rpath), varLst=varLst))), _, _, _)
      equation
        true = Absyn.pathEqual(path, rpath);
        ht = HashSet.emptyHashSet();
        ht = List.fold(crefs, BaseHashSet.add, ht);
        List.foldAllValue(expLst, createSingleComplexEqnCode3, true, ht);
        (e1_1, _) = Expression.extendArrExp(e1, false);
        // true = ComponentReference.crefEqualNoStringCompare(cr, cr2);
        // tmp = f()
        ident = Absyn.pathStringUnquoteReplaceDot(path, "_");
        cr1 = ComponentReference.makeCrefIdent("$TMP_" + ident + intString(iuniqueEqIndex), tp, {});
        e2_1 = Expression.crefExp(cr1);
        stms = DAE.STMT_ASSIGN(tp, e2_1, e1_1, source);
        simeqn = SimCode.SES_ALGORITHM(iuniqueEqIndex, {stms});
        uniqueEqIndex = iuniqueEqIndex + 1;
        // Record()=tmp
        crexplst = List.map1(varLst, Expression.generateCrefsExpFromExpVar, cr1);
        exptl = List.threadTuple(expLst, crexplst);
        (eqSystlst, uniqueEqIndex) = List.map1Fold(exptl, makeSES_SIMPLE_ASSIGN, source, uniqueEqIndex);
        eqSystlst = simeqn::eqSystlst;
        tempvars = createTempVars(varLst, cr1, itempvars);
      then
        (eqSystlst, uniqueEqIndex, tempvars);

    /* Tuple() = f()  */
    case (_, e1 as DAE.TUPLE(expl), e2 as DAE.CALL(), _, _, _)
      equation
        tp = Expression.typeof(e1);

        //check that solved vars are on lhs
        ht = HashSet.emptyHashSet();
        ht = List.fold(crefs, BaseHashSet.add, ht);
        List.foldAllValue(expl, createSingleComplexEqnCode3, true, ht);

        eqSystlst = {SimCode.SES_ALGORITHM(iuniqueEqIndex, {DAE.STMT_TUPLE_ASSIGN(tp, expl, e2, source)})};
        uniqueEqIndex = iuniqueEqIndex + 1;
      then
        (eqSystlst, uniqueEqIndex, itempvars);

    // Tuple(crefs) = Tuple(expl)
    case (_, e1 as DAE.TUPLE(expl), DAE.TUPLE(expl1), _, _, _)
      equation
        _ = Expression.typeof(e1);
        //print("Tuple crefs Strings: "+ ComponentReference.printComponentRefListStr(crefs) + "\n");
        //check that all crefs are on lhs
        ht = HashSet.emptyHashSet();
        ht = List.fold(crefs, BaseHashSet.add, ht);
        List.foldAllValue(expl, createSingleComplexEqnCode3, true, ht);

        expLst = List.map(crefs, Expression.crefExp);
        //print("ExpList : " + ExpressionDump.printExpListStr(expLst) + "\n");
        positions = List.map1(expLst, List.position, expl);
        //print("Positions : " + stringDelimitList(List.map(positions, intString), ", ") + "\n");
        expLst = List.map1r(positions, listGet, expl1);
        //print("ExpList rhs : " + ExpressionDump.printExpListStr(expLst) + "\n");
        expl = List.map1r(positions, listGet, expl);
        //print("ExpList lhs : " + ExpressionDump.printExpListStr(expl) + "\n");

        exptl = List.threadTuple(expl, expLst);
        (eqSystlst, uniqueEqIndex) = List.map1Fold(exptl, makeSES_SIMPLE_ASSIGN, source, iuniqueEqIndex);
      then
        (eqSystlst, uniqueEqIndex, itempvars);

    // Tuple(expl) = Tuple(crefs)
    case (_, e1 as DAE.TUPLE(expl1), DAE.TUPLE(expl), _, _, _)
      equation
        _ = Expression.typeof(e1);
        //check that all crefs are on rhs
        ht = HashSet.emptyHashSet();
        ht = List.fold(crefs, BaseHashSet.add, ht);
        List.foldAllValue(expl, createSingleComplexEqnCode3, true, ht);

        expLst = List.map(crefs, Expression.crefExp);
        positions = List.map1(expLst, List.position, expl);
        expLst = List.map1r(positions, listGet, expl1);
        expl = List.map1r(positions, listGet, expl);

        exptl = List.threadTuple(expl, expLst);
        (eqSystlst, uniqueEqIndex) = List.map1Fold(exptl, makeSES_SIMPLE_ASSIGN, source, iuniqueEqIndex);
      then
        (eqSystlst, uniqueEqIndex, itempvars);


    // failure
    case (_, e1, e2, _, _, _)
      equation
        true = Flags.isSet(Flags.FAILTRACE);
        s1 = ExpressionDump.printExpStr(e1);
        s2 = ExpressionDump.printExpStr(e2);
        s3 = ComponentReference.printComponentRefListStr(crefs);
        s = stringAppendList({"function createSingleComplexEqnCode2 failed for: ", s1, " = " , s2, " solve for ", s3 });
        Debug.traceln(s);
    then
      fail();
  end matchcontinue;
end createSingleComplexEqnCode2;

protected function createSingleComplexEqnCode3
  input DAE.Exp inExp;
  input HashSet.HashSet iht;
  output Boolean outB;
  output HashSet.HashSet oht;
algorithm
  (outB, oht) := matchcontinue(inExp, iht)
    local
      DAE.ComponentRef cr;
      HashSet.HashSet ht;
      list<DAE.ComponentRef> crefs;
      list<DAE.Exp> expLst;

    case (DAE.CREF(componentRef=cr), _)
      equation
        _ = BaseHashSet.get(cr, iht);
        ht = BaseHashSet.delete(cr, iht);
      then
        (true, ht);
    /* consider also array and record crefs */
    case (DAE.CREF(componentRef=cr), _)
      equation
        crefs = ComponentReference.expandCref(cr, true);
        false = valueEq({cr},crefs); // Not an expanded element
        expLst = List.map(crefs, Expression.crefExp);
        List.foldAllValue(expLst, createSingleComplexEqnCode3, true, iht);
      then (true, iht);
    case (DAE.RCONST(_), _) then (true, iht);
    case (DAE.ICONST(_), _) then (true, iht);
    case (DAE.BCONST(_), _) then (true, iht);
    case (DAE.CREF(componentRef=DAE.WILD()), _) then (true, iht);
    else
      (false, iht);
  end matchcontinue;
end createSingleComplexEqnCode3;

protected function createSingleArrayEqnCode
  input Boolean genDiscrete;
  input list<BackendDAE.Equation> inEquations;
  input list<BackendDAE.Var> inVars;
  input Integer iuniqueEqIndex;
  input list<SimCodeVar.SimVar> itempvars;
  input BackendDAE.ExtraInfo iextra;
  output list<SimCode.SimEqSystem> equations_;
  output list<SimCode.SimEqSystem> noDiscequations;
  output Integer ouniqueEqIndex;
  output list<SimCodeVar.SimVar> otempvars;
algorithm
  (equations_, noDiscequations, ouniqueEqIndex, otempvars) := matchcontinue(genDiscrete, inEquations, inVars, iuniqueEqIndex, itempvars, iextra)
    local
      list<Integer> ds;
      DAE.Exp e1, e2;
      list<DAE.Exp> ea1, ea2;
      list<BackendDAE.Equation> re;
      list<BackendDAE.Var> vars;
      DAE.ComponentRef cr, cr_1;
      BackendDAE.Variables evars, vars1;
      BackendDAE.EquationArray eeqns, eqns_1;
      FCore.Cache cache;
      FCore.Graph graph;
      DAE.FunctionTree funcs;
      DAE.ElementSource source;
      BackendDAE.Variables av;
      BackendDAE.BackendDAE subsystem_dae;
      SimCode.SimEqSystem equation_;
      BackendDAE.StrongComponents comps;
      BackendDAE.EqSystem syst;
      BackendDAE.Shared shared;
      Integer uniqueEqIndex;
      String str;
      list<list<DAE.Subscript>> subslst;
      list<SimCodeVar.SimVar> tempvars;
      BackendDAE.EquationKind eqKind;

    case (_, BackendDAE.ARRAY_EQUATION(left=e1, right=e2, source=source)::_, BackendDAE.VAR(varName = cr)::_, _, _, _) equation
      // We need to strip subs from the name since they are removed in cr.
      cr_1 = ComponentReference.crefStripLastSubs(cr);
      e1 = Expression.replaceDerOpInExp(e1);
      e2 = Expression.replaceDerOpInExp(e2);
      (e1, _) = BackendDAEUtil.collateArrExp(e1, NONE());
      (e2, _) = BackendDAEUtil.collateArrExp(e2, NONE());
      (e1, e2) = solveTrivialArrayEquation(cr_1, e1, e2);
      (equation_, uniqueEqIndex) = createSingleArrayEqnCode2(cr_1, cr_1, e1, e2, iuniqueEqIndex, source);
    then ({equation_}, {equation_}, uniqueEqIndex, itempvars);

    case (_, BackendDAE.ARRAY_EQUATION(left=e1, right=e2, source=source, attr=BackendDAE.EQUATION_ATTRIBUTES(kind=eqKind))::_, vars, _, _, _) equation
      true = Expression.isArray(e1) or Expression.isMatrix(e1);
      true = Expression.isArray(e2) or Expression.isMatrix(e2);
      e1 = Expression.replaceDerOpInExp(e1);
      e2 = Expression.replaceDerOpInExp(e2);
      ea1 = Expression.flattenArrayExpToList(e1);
      ea2 = Expression.flattenArrayExpToList(e2);
      ea1 = BackendDAEUtil.collateArrExpList(ea1, NONE());
      ea2 = BackendDAEUtil.collateArrExpList(ea2, NONE());
      re = List.threadMap2(ea1, ea2, BackendEquation.generateEQUATION, source, eqKind);
      eqns_1 = BackendEquation.listEquation(re);
      av = BackendVariable.emptyVars();
      eeqns = BackendEquation.emptyEqns();
      evars = BackendVariable.listVar1({});
      cache = FCore.emptyCache();
      graph = FGraph.empty();
      funcs = DAEUtil.avlTreeNew();
      vars1 = BackendVariable.listVar1(vars);
      syst = BackendDAE.EQSYSTEM(vars1, eqns_1, NONE(), NONE(), BackendDAE.NO_MATCHING(), {}, BackendDAE.UNKNOWN_PARTITION());
      shared = BackendDAE.SHARED(evars, evars, av, eeqns, eeqns, {}, {}, cache, graph, funcs, BackendDAE.EVENT_INFO({}, {}, {}, {}, {}, 0), {}, BackendDAE.ARRAYSYSTEM(), {}, iextra);
      subsystem_dae = BackendDAE.DAE({syst}, shared);
      (BackendDAE.DAE({syst as BackendDAE.EQSYSTEM(matching=BackendDAE.MATCHING(comps=comps))}, shared)) = BackendDAEUtil.transformBackendDAE(subsystem_dae, SOME((BackendDAE.NO_INDEX_REDUCTION(), BackendDAE.ALLOW_UNDERCONSTRAINED())), NONE(), NONE());
      (equations_, noDiscequations, uniqueEqIndex, tempvars) = createEquations(false, false, genDiscrete, false, syst, shared, comps, iuniqueEqIndex, itempvars);
    then (equations_, noDiscequations, uniqueEqIndex, tempvars);

    case (_, BackendDAE.ARRAY_EQUATION(dimSize=ds, left=e1, right=e2, source=source, attr=BackendDAE.EQUATION_ATTRIBUTES(kind=eqKind))::_, vars, _, _, _) equation
      e1 = Expression.replaceDerOpInExp(e1);
      e2 = Expression.replaceDerOpInExp(e2);
      subslst = Expression.dimensionSizesSubscripts(ds);
      subslst = Expression.rangesToSubscripts(subslst);
      ea1 = List.map1r(subslst, Expression.applyExpSubscripts, e1);
      ea2 = List.map1r(subslst, Expression.applyExpSubscripts, e2);
      re = List.threadMap2(ea1, ea2, BackendEquation.generateEQUATION, source, eqKind);
      eqns_1 = BackendEquation.listEquation(re);
      av = BackendVariable.emptyVars();
      eeqns = BackendEquation.emptyEqns();
      evars = BackendVariable.listVar1({});
      cache = FCore.emptyCache();
      graph = FGraph.empty();
      funcs = DAEUtil.avlTreeNew();
      vars1 = BackendVariable.listVar1(vars);
      syst = BackendDAE.EQSYSTEM(vars1, eqns_1, NONE(), NONE(), BackendDAE.NO_MATCHING(), {}, BackendDAE.UNKNOWN_PARTITION());
      shared = BackendDAE.SHARED(evars, evars, av, eeqns, eeqns, {}, {}, cache, graph, funcs, BackendDAE.EVENT_INFO({}, {}, {}, {}, {}, 0), {}, BackendDAE.ARRAYSYSTEM(), {}, iextra);
      subsystem_dae = BackendDAE.DAE({syst}, shared);
      (BackendDAE.DAE({syst as BackendDAE.EQSYSTEM(matching=BackendDAE.MATCHING(comps=comps))}, shared)) = BackendDAEUtil.transformBackendDAE(subsystem_dae, SOME((BackendDAE.NO_INDEX_REDUCTION(), BackendDAE.ALLOW_UNDERCONSTRAINED())), NONE(), NONE());
      (equations_, noDiscequations, uniqueEqIndex, tempvars) = createEquations(false, false, genDiscrete, false, syst, shared, comps, iuniqueEqIndex, itempvars);
    then (equations_, noDiscequations, uniqueEqIndex, tempvars);

    // failure
    else equation
      str = BackendDump.dumpEqnsStr(inEquations);
      str = "for Eqn: " + str + "\narray equations currently only supported on form v = functioncall(...)";
      Error.addMessage(Error.INTERNAL_ERROR, {str});
    then fail();
  end matchcontinue;
end createSingleArrayEqnCode;

protected function createSingleAlgorithmCode
  input list<BackendDAE.Equation> eqns;
  input list<BackendDAE.Var> vars;
  input Boolean skipDiscinAlgorithm;
  input Integer iuniqueEqIndex;
  output list<SimCode.SimEqSystem> equations_;
  output Integer ouniqueEqIndex;
algorithm
  (equations_, ouniqueEqIndex) := matchcontinue (eqns, vars, skipDiscinAlgorithm, iuniqueEqIndex)
    local
      DAE.Algorithm alg;
      list<DAE.ComponentRef> solvedVars, algOutVars;
      String message, algStr;
      list<DAE.Statement> algStatements;
      DAE.ElementSource source;
      DAE.Expand crefExpand;

      // normal call
    case (BackendDAE.ALGORITHM(alg=alg, source = source, expand=crefExpand)::_, _, false, _)
      equation
        solvedVars = List.map(vars, BackendVariable.varCref);
        algOutVars = CheckModel.checkAndGetAlgorithmOutputs(alg, source, crefExpand);
        // The variables solved for musst all be part of the output variables of the algorithm.
        List.map2AllValue(solvedVars, List.isMemberOnTrue, true, algOutVars, ComponentReference.crefEqualNoStringCompare);
        DAE.ALGORITHM_STMTS(algStatements) = BackendDAEUtil.collateAlgorithm(alg, NONE());
      then
        ({SimCode.SES_ALGORITHM(iuniqueEqIndex, algStatements)}, iuniqueEqIndex+1);

        // remove discrete Vars
    case (BackendDAE.ALGORITHM(alg=alg, source=source, expand=crefExpand)::_, _, true, _)
      equation
        solvedVars = List.map(vars, BackendVariable.varCref);
        algOutVars = CheckModel.checkAndGetAlgorithmOutputs(alg, source, crefExpand);
        // The variables solved for musst all be part of the output variables of the algorithm.
        List.map2AllValue(solvedVars, List.isMemberOnTrue, true, algOutVars, ComponentReference.crefEqualNoStringCompare);
        DAE.ALGORITHM_STMTS(algStatements) = BackendDAEUtil.collateAlgorithm(alg, NONE());
        algStatements = BackendDAEUtil.removeDiscreteAssignments(algStatements, BackendVariable.listVar1(vars));
      then
        ({SimCode.SES_ALGORITHM(iuniqueEqIndex, algStatements)}, iuniqueEqIndex+1);

        // inverse Algorithm for single variable.
    case (BackendDAE.ALGORITHM(alg=alg, source=source, expand=crefExpand)::_, _, false, _)
      equation
        _ = List.map(vars, BackendVariable.varCref);
        _ = CheckModel.checkAndGetAlgorithmOutputs(alg, source, crefExpand);
        // We need to solve an inverse problem of an algorithm section.
        DAE.ALGORITHM_STMTS(algStatements) = BackendDAEUtil.collateAlgorithm(alg, NONE());
        algStatements = solveAlgorithmInverse(algStatements, vars);
      then
        ({SimCode.SES_ALGORITHM(iuniqueEqIndex, algStatements)}, iuniqueEqIndex+1);

        // Error message, inverse algorithms not supported yet
    case (BackendDAE.ALGORITHM(alg=alg, source=source, expand=crefExpand)::_, _, _, _)
      equation
        solvedVars = List.map(vars, BackendVariable.varCref);
        algOutVars = CheckModel.checkAndGetAlgorithmOutputs(alg, source, crefExpand);
        // The variables solved for musst all be part of the output variables of the algorithm.
        failure(List.map2AllValue(solvedVars, List.isMemberOnTrue, true, algOutVars, ComponentReference.crefEqualNoStringCompare));
        algStr =  DAEDump.dumpAlgorithmsStr({DAE.ALGORITHM(alg, source)});
        message = ComponentReference.printComponentRefListStr(solvedVars);
        message = stringAppendList({"Inverse Algorithm needs to be solved for ", message, " in \n", algStr, "This has not been implemented yet.\n"});
        Error.addMessage(Error.INTERNAL_ERROR, {message});
      then
         fail();
    // failure
    else
      equation
        Error.addMessage(Error.INTERNAL_ERROR, {"function createSingleAlgorithmCode failed!"});
      then
        fail();
  end matchcontinue;
end createSingleAlgorithmCode;

// TODO: are the cases really correct?
protected function createSingleArrayEqnCode2
  input DAE.ComponentRef inComponentRef1;
  input DAE.ComponentRef inComponentRef2;
  input DAE.Exp inExp3;
  input DAE.Exp inExp4;
  input Integer iuniqueEqIndex;
  input DAE.ElementSource source;
  output SimCode.SimEqSystem equation_;
  output Integer ouniqueEqIndex;
algorithm
  (equation_, ouniqueEqIndex) := matchcontinue (inComponentRef1, inComponentRef2, inExp3, inExp4, iuniqueEqIndex, source)
    local
      DAE.ComponentRef cr, eltcr, cr2;
      DAE.Exp e1, e2;
      DAE.Type ty;

    case (cr, eltcr, (DAE.CREF(componentRef = cr2)), e2, _, _)
      equation
        true = ComponentReference.crefEqualNoStringCompare(cr, cr2);
      then
        (SimCode.SES_ARRAY_CALL_ASSIGN(iuniqueEqIndex, eltcr, e2, source), iuniqueEqIndex+1);

    case (cr, eltcr, e1, (DAE.CREF(componentRef = cr2)), _, _)
      equation
        true = ComponentReference.crefEqualNoStringCompare(cr, cr2);
      then
        (SimCode.SES_ARRAY_CALL_ASSIGN(iuniqueEqIndex, eltcr, e1, source), iuniqueEqIndex+1);

    case (cr, eltcr, (DAE.UNARY(exp=DAE.CREF(componentRef = cr2))), e2, _, _)
      equation
        true = ComponentReference.crefEqualNoStringCompare(cr, cr2);
        _ = Expression.typeof(e2);
        e2 = Expression.negate(e2);
      then
        (SimCode.SES_ARRAY_CALL_ASSIGN(iuniqueEqIndex, eltcr, e2, source), iuniqueEqIndex+1);

    case (cr, eltcr, e1, (DAE.UNARY(exp=DAE.CREF(componentRef = cr2))), _, _)
      equation
        true = ComponentReference.crefEqualNoStringCompare(cr, cr2);
        e1 = Expression.negate(e1);
      then
        (SimCode.SES_ARRAY_CALL_ASSIGN(iuniqueEqIndex, eltcr, e1, source), iuniqueEqIndex+1);

    case (_, _, e1, DAE.UNARY(DAE.UMINUS_ARR(_), e2), _, _)
      equation
        cr2 = getVectorizedCrefFromExp(e2);
        e1 = Expression.negate(e1);
      then
        (SimCode.SES_ARRAY_CALL_ASSIGN(iuniqueEqIndex, cr2, e1, source), iuniqueEqIndex+1);

    case (_, _, DAE.UNARY(DAE.UMINUS_ARR(_), e1), e2, _, _) /* e2 is array of crefs, {v{1}, v{2}, ...v{n}} */
      equation
        cr2 = getVectorizedCrefFromExp(e1);
        e2 = Expression.negate(e2);
      then
        (SimCode.SES_ARRAY_CALL_ASSIGN(iuniqueEqIndex, cr2, e2, source), iuniqueEqIndex+1);

    case (_, _, e1, e2, _, _) /* e2 is array of crefs, {v{1}, v{2}, ...v{n}} */
      equation
        cr2 = getVectorizedCrefFromExp(e2);
      then
        (SimCode.SES_ARRAY_CALL_ASSIGN(iuniqueEqIndex, cr2, e1, source), iuniqueEqIndex+1);

    case (_, _, e1, e2, _, _) /* e1 is array of crefs, {v{1}, v{2}, ...v{n}} */
      equation
        cr2 = getVectorizedCrefFromExp(e1);
      then
        (SimCode.SES_ARRAY_CALL_ASSIGN(iuniqueEqIndex, cr2, e2, source), iuniqueEqIndex+1);

/*
    case (cr, _, e1, e2, _, _)
       equation
       s1 = ExpressionDump.printExpStr(e1);
       s2 = ExpressionDump.printExpStr(e2);
       s3 = ComponentReference.crefStr(cr);
       s = stringAppendList({"function createSingleArrayEqnCode2 failed for: ", s1, " = " , s2, " solve for ", s3 });
       Error.addMessage(Error.INTERNAL_ERROR, {s});
    then
      fail();
*/
  end matchcontinue;
end createSingleArrayEqnCode2;

protected function createInitialResiduals "author: lochel
  This function generates all initial_residuals."
  input BackendDAE.BackendDAE inDAE;
  input Option<BackendDAE.BackendDAE> inInitDAE;
  input List<BackendDAE.Equation> inRemovedEqnLst;
  input Integer iuniqueEqIndex;
  input list<SimCodeVar.SimVar> itempvars;
  output list<SimCode.SimEqSystem> outResiduals;
  output list<SimCode.SimEqSystem> outInitialEqns;
  output list<SimCode.SimEqSystem> outRemovedInitialEqns;
  output Integer outNumberOfInitialEquations;
  output Integer outNumberOfInitialAlgorithms;
  output Integer ouniqueEqIndex;
  output list<SimCodeVar.SimVar> otempvars;
  output Boolean useSymbolicInitialization;
algorithm
  (outResiduals, outInitialEqns, outRemovedInitialEqns, outNumberOfInitialEquations, outNumberOfInitialAlgorithms, ouniqueEqIndex, otempvars, useSymbolicInitialization) :=
  matchcontinue(inDAE, inInitDAE, inRemovedEqnLst, iuniqueEqIndex, itempvars)
    local
      BackendDAE.EquationArray  removedEqs;
      list<SimCodeVar.SimVar> tempvars;
      Integer uniqueEqIndex;

      list<BackendDAE.Equation> initialEqs_lst;
      Integer numberOfInitialEquations, numberOfInitialAlgorithms;

      list<SimCode.SimEqSystem> residual_equations,  allEquations, removedEquations, knvarseqns, aliasEquations, removedInitialEquations;
      BackendDAE.EqSystems systs;
      BackendDAE.Shared shared;
      BackendDAE.Variables knvars, aliasVars;

    // try to solve the inital system symbolical.
    case (_, SOME(BackendDAE.DAE(systs,
                                 shared as BackendDAE.SHARED(knownVars=knvars,
                                                             aliasVars=aliasVars,
                                                             removedEqs=removedEqs))), _, _, _) equation
      // generate equations from the solved systems
      (uniqueEqIndex, _, _, allEquations, _, tempvars, _, _, _) = createEquationsForSystems(systs, shared, iuniqueEqIndex, {}, {}, {}, {}, {}, itempvars, 0, {}, {}, SimCode.NO_MAPPING());
      // generate equations from the removed equations
      ((uniqueEqIndex, removedEquations)) = BackendEquation.traverseEquationArray(removedEqs, traversedlowEqToSimEqSystem, (uniqueEqIndex, {}));
      allEquations = listAppend(allEquations, removedEquations);
      // generate equations from the known unfixed variables
      ((uniqueEqIndex, knvarseqns)) = BackendVariable.traverseBackendDAEVars(knvars, traverseKnVarsToSimEqSystem, (uniqueEqIndex, {}));
      allEquations = listAppend(allEquations, knvarseqns);
      // generate equations from the alias variables
      ((uniqueEqIndex, aliasEquations)) = BackendVariable.traverseBackendDAEVars(aliasVars, traverseAliasVarsToSimEqSystem, (uniqueEqIndex, {}));
      allEquations = listAppend(allEquations, aliasEquations);

      // generate equations from removed initial equations
      (removedInitialEquations, uniqueEqIndex, tempvars) = createNonlinearResidualEquations(inRemovedEqnLst, uniqueEqIndex, tempvars);

      // also generate all the stuff for the numerical initialization
      (initialEqs_lst, numberOfInitialEquations, numberOfInitialAlgorithms) = BackendDAEOptimize.collectInitialEquations(inDAE);
      (residual_equations, uniqueEqIndex, tempvars) = createNonlinearResidualEquations(initialEqs_lst, uniqueEqIndex, tempvars);
    then (residual_equations, allEquations, removedInitialEquations, numberOfInitialEquations, numberOfInitialAlgorithms, uniqueEqIndex, tempvars, true);

    case (_, _, _, _, _) equation
      (initialEqs_lst, numberOfInitialEquations, numberOfInitialAlgorithms) = BackendDAEOptimize.collectInitialEquations(inDAE);
      (residual_equations, uniqueEqIndex, tempvars) = createNonlinearResidualEquations(initialEqs_lst, iuniqueEqIndex, itempvars);
      Error.addCompilerWarning("No system for the symbolic initialization was generated. A method using numerical algorithms will be used instead.");
    then (residual_equations, {}, {}, numberOfInitialEquations, numberOfInitialAlgorithms, uniqueEqIndex, tempvars, false);

    else equation
      Error.addMessage(Error.INTERNAL_ERROR, {"function createInitialResiduals failed"});
    then fail();
  end matchcontinue;
end createInitialResiduals;

protected function traverseKnVarsToSimEqSystem
  "author: Frenkel TUD 2012-10"
   input BackendDAE.Var inVar;
   input tuple<Integer, list<SimCode.SimEqSystem>> inTpl;
   output BackendDAE.Var outVar;
   output tuple<Integer, list<SimCode.SimEqSystem>> outTpl;
algorithm
  (outVar,outTpl) := matchcontinue (inVar,inTpl)
    local
      BackendDAE.Var v;
      Integer uniqueEqIndex;
      list<SimCode.SimEqSystem> eqns;
      DAE.ComponentRef cr;
      DAE.Exp exp;
      DAE.ElementSource source;
    case (v as BackendDAE.VAR(varName = cr, bindExp=SOME(exp), source=source), (uniqueEqIndex, eqns))
      equation
        false = BackendVariable.varFixed(v);
        false = BackendVariable.isVarOnTopLevelAndInput(v);
      then
        (v, (uniqueEqIndex+1, SimCode.SES_SIMPLE_ASSIGN(uniqueEqIndex, cr, exp, source)::eqns));
    else (inVar,inTpl);
  end matchcontinue;
end traverseKnVarsToSimEqSystem;

protected function traverseAliasVarsToSimEqSystem
  "author: Frenkel TUD 2012-10"
   input BackendDAE.Var inVar;
   input tuple<Integer, list<SimCode.SimEqSystem>> inTpl;
   output BackendDAE.Var outVar;
   output tuple<Integer, list<SimCode.SimEqSystem>> outTpl;
algorithm
  (outVar,outTpl) := match (inVar,inTpl)
    local
      BackendDAE.Var v;
      Integer uniqueEqIndex;
      list<SimCode.SimEqSystem> eqns;
      DAE.ComponentRef cr;
      DAE.Exp exp;
      DAE.ElementSource source;
    case (v as BackendDAE.VAR(varName = cr, bindExp=SOME(exp), source=source), (uniqueEqIndex, eqns))
      then
        (v, (uniqueEqIndex+1, SimCode.SES_SIMPLE_ASSIGN(uniqueEqIndex, cr, exp, source)::eqns));
  end match;
end traverseAliasVarsToSimEqSystem;

protected function dlowEqToSimEqSystem
  input BackendDAE.Equation inEquation;
  input Integer iuniqueEqIndex;
  output SimCode.SimEqSystem outEquation;
  output Integer ouniqueEqIndex;
algorithm
  (outEquation, ouniqueEqIndex) := match (inEquation, iuniqueEqIndex)
    local
      DAE.ComponentRef cr;
      DAE.Exp exp_;
      DAE.Algorithm alg;
      list<DAE.Statement> algStatements;
      DAE.ElementSource source;

    case (BackendDAE.SOLVED_EQUATION(componentRef=cr, exp=exp_, source=source), _) then (SimCode.SES_SIMPLE_ASSIGN(iuniqueEqIndex, cr, exp_, source), iuniqueEqIndex+1);

    case (BackendDAE.RESIDUAL_EQUATION(exp=exp_, source=source), _) then (SimCode.SES_RESIDUAL(iuniqueEqIndex, exp_, source), iuniqueEqIndex+1);

    case (BackendDAE.ALGORITHM(alg=alg), _)
      equation
        DAE.ALGORITHM_STMTS(algStatements) = BackendDAEUtil.collateAlgorithm(alg, NONE());
      then
        (SimCode.SES_ALGORITHM(iuniqueEqIndex, algStatements), iuniqueEqIndex+1);

  end match;
end dlowEqToSimEqSystem;

protected function dlowAlgToSimEqSystem
  input DAE.Algorithm inAlg;
  input Integer iuniqueEqIndex;
  output SimCode.SimEqSystem outEquation;
  output Integer ouniqueEqIndex;
algorithm
  (outEquation, ouniqueEqIndex) := match (inAlg, iuniqueEqIndex)
    local
      list<DAE.Statement> algStatements;
    case (_, _)
      equation
        DAE.ALGORITHM_STMTS(algStatements) = BackendDAEUtil.collateAlgorithm(inAlg, NONE());
      then
        (SimCode.SES_ALGORITHM(iuniqueEqIndex, algStatements), iuniqueEqIndex+1);
  end match;
end dlowAlgToSimEqSystem;

protected function createVarNominalAssertFromVars
  input BackendDAE.EqSystem syst;
  input BackendDAE.Shared shared;
  input tuple<Integer, list<SimCode.SimEqSystem>> acc;
  output tuple<Integer, list<SimCode.SimEqSystem>> nominalAsserts;
algorithm
  nominalAsserts := match (syst, shared, acc)
    local
      list<DAE.Algorithm> asserts1;
      list<SimCode.SimEqSystem> asserts2;
      BackendDAE.Variables vars;
      Integer uniqueEqIndex;
      list<SimCode.SimEqSystem> simeqns;
    case (BackendDAE.EQSYSTEM(orderedVars=vars), _, (uniqueEqIndex, simeqns))
      equation
        asserts1 = BackendVariable.traverseBackendDAEVars(vars, createVarNominalAssert, {});
        (asserts2, uniqueEqIndex) = List.mapFold(asserts1, dlowAlgToSimEqSystem, uniqueEqIndex);
      then ((uniqueEqIndex, listAppend(asserts2, simeqns)));
  end match;
end createVarNominalAssertFromVars;

protected function createStartValueEquations
  input BackendDAE.EqSystem syst;
  input BackendDAE.Shared shared;
  input tuple<Integer, list<SimCode.SimEqSystem>> acc;
  output tuple<Integer, list<SimCode.SimEqSystem>> startValueEquations;
algorithm
  startValueEquations := matchcontinue (syst, shared, acc)
    local
      BackendDAE.Variables vars, av;
      list<BackendDAE.Equation>  startValueEquationsTmp2;
      list<SimCode.SimEqSystem> simeqns, simeqns1;
      Integer uniqueEqIndex;

    // this is the old version if the new fails
    case (BackendDAE.EQSYSTEM(orderedVars=vars), BackendDAE.SHARED(aliasVars=av), (uniqueEqIndex, simeqns)) equation
      // vars
      ((startValueEquationsTmp2, _)) = BackendVariable.traverseBackendDAEVars(vars, createInitialAssignmentsFromStart, ({}, av));
      startValueEquationsTmp2 = listReverse(startValueEquationsTmp2);
      // kvars
      // ((startValueEquationsTmp, _)) = BackendVariable.traverseBackendDAEVars(knvars, createInitialAssignmentsFromStart, ({}, av));
      // startValueEquationsTmp = listReverse(startValueEquationsTmp);
      // startValueEquationsTmp2 = listAppend(startValueEquationsTmp2, startValueEquationsTmp);

      (simeqns1, uniqueEqIndex) = List.mapFold(startValueEquationsTmp2, dlowEqToSimEqSystem, uniqueEqIndex);
    then
      ((uniqueEqIndex, listAppend(simeqns1, simeqns)));

    else equation
      Error.addMessage(Error.INTERNAL_ERROR, {"createStartValueEquations failed"});
    then fail();
  end matchcontinue;
end createStartValueEquations;

protected function createNominalValueEquations
  input BackendDAE.EqSystem syst;
  input BackendDAE.Shared shared;
  input tuple<Integer, list<SimCode.SimEqSystem>> acc;
  output tuple<Integer, list<SimCode.SimEqSystem>> nominalValueEquations;
algorithm
  nominalValueEquations := matchcontinue (syst, shared, acc)
    local
      BackendDAE.Variables vars, av;
      list<BackendDAE.Equation> nominalValueEquationsTmp2;
      list<SimCode.SimEqSystem> simeqns, simeqns1;
      Integer uniqueEqIndex;

    case (BackendDAE.EQSYSTEM(orderedVars=vars), BackendDAE.SHARED(aliasVars=av), (uniqueEqIndex, simeqns)) equation
      // vars
      ((nominalValueEquationsTmp2, _)) = BackendVariable.traverseBackendDAEVars(vars, createInitialAssignmentsFromNominal, ({}, av));
      nominalValueEquationsTmp2 = listReverse(nominalValueEquationsTmp2);

      // kvars -> see createStartValueEquations

      (simeqns1, uniqueEqIndex) = List.mapFold(nominalValueEquationsTmp2, dlowEqToSimEqSystem, uniqueEqIndex);
    then ((uniqueEqIndex, listAppend(simeqns1, simeqns)));

    else equation
      Error.addMessage(Error.INTERNAL_ERROR, {"createNominalValueEquations failed"});
    then fail();
  end matchcontinue;
end createNominalValueEquations;

protected function createMinValueEquations
  input BackendDAE.EqSystem syst;
  input BackendDAE.Shared shared;
  input tuple<Integer, list<SimCode.SimEqSystem>> acc;
  output tuple<Integer, list<SimCode.SimEqSystem>> minValueEquations;
algorithm
  minValueEquations := matchcontinue (syst, shared, acc)
    local
      BackendDAE.Variables vars, av;
      list<BackendDAE.Equation> minValueEquationsTmp2;
      list<SimCode.SimEqSystem> simeqns, simeqns1;
      Integer uniqueEqIndex;

    case (BackendDAE.EQSYSTEM(orderedVars=vars), BackendDAE.SHARED(aliasVars=av), (uniqueEqIndex, simeqns)) equation
      // vars
      ((minValueEquationsTmp2, _)) = BackendVariable.traverseBackendDAEVars(vars, createInitialAssignmentsFromMin, ({}, av));
      minValueEquationsTmp2 = listReverse(minValueEquationsTmp2);

      // kvars -> see createStartValueEquations

      (simeqns1, uniqueEqIndex) = List.mapFold(minValueEquationsTmp2, dlowEqToSimEqSystem, uniqueEqIndex);
    then ((uniqueEqIndex, listAppend(simeqns1, simeqns)));

    else equation
      Error.addMessage(Error.INTERNAL_ERROR, {"createMinValueEquations failed"});
    then fail();
  end matchcontinue;
end createMinValueEquations;

protected function createMaxValueEquations
  input BackendDAE.EqSystem syst;
  input BackendDAE.Shared shared;
  input tuple<Integer, list<SimCode.SimEqSystem>> acc;
  output tuple<Integer, list<SimCode.SimEqSystem>> maxValueEquations;
algorithm
  maxValueEquations := matchcontinue (syst, shared, acc)
    local
      BackendDAE.Variables vars, av;
      list<BackendDAE.Equation> maxValueEquationsTmp2;
      list<SimCode.SimEqSystem> simeqns, simeqns1;
      Integer uniqueEqIndex;

    case (BackendDAE.EQSYSTEM(orderedVars=vars), BackendDAE.SHARED(aliasVars=av), (uniqueEqIndex, simeqns)) equation
      // vars
      ((maxValueEquationsTmp2, _)) = BackendVariable.traverseBackendDAEVars(vars, createInitialAssignmentsFromMax, ({}, av));
      maxValueEquationsTmp2 = listReverse(maxValueEquationsTmp2);

      // kvars -> see createStartValueEquations

      (simeqns1, uniqueEqIndex) = List.mapFold(maxValueEquationsTmp2, dlowEqToSimEqSystem, uniqueEqIndex);
    then ((uniqueEqIndex, listAppend(simeqns1, simeqns)));

    else equation
      Error.addMessage(Error.INTERNAL_ERROR, {"createMaxValueEquations failed"});
    then fail();
  end matchcontinue;
end createMaxValueEquations;

protected function createParameterEquations
  input BackendDAE.Shared inShared;
  input Integer iuniqueEqIndex;
  input list<SimCode.SimEqSystem> acc;
  input Boolean initialSystemSolved;
  output Integer ouniqueEqIndex;
  output list<SimCode.SimEqSystem> parameterEquations;
algorithm
  (ouniqueEqIndex, parameterEquations) := matchcontinue (inShared, iuniqueEqIndex, acc, initialSystemSolved)
    local
      list<BackendDAE.Equation> parameterEquationsTmp;
      BackendDAE.Variables knvars, extobj, v, kn;
      list<DAE.Constraint> constrs;
      list<DAE.ClassAttributes> clsAttrs;
      BackendDAE.EquationArray ie, pe, emptyeqns, remeqns;
      list<SimCode.SimEqSystem> simvarasserts, inalgs;
      list<DAE.Algorithm> varasserts, ialgs;
      BackendDAE.BackendDAE paramdlow;
      BackendDAE.ExternalObjectClasses extObjClasses;
      BackendDAE.IncidenceMatrix m;
      BackendDAE.IncidenceMatrixT mT;
      array<Integer> v1, v2;
      list<Integer> lv1, lv2;
      BackendDAE.StrongComponents comps;
      list<BackendDAE.Var> lv, lkn;
      BackendDAE.Shared shared;
      BackendDAE.EqSystem syst;
      BackendDAE.Variables aliasVars, alisvars;

      FCore.Cache cache;
      FCore.Graph graph;
      DAE.FunctionTree funcs;
      BackendDAE.EventInfo einfo;
      BackendDAE.BackendDAEType btp;
      BackendDAE.SymbolicJacobians symjacs;
      Integer uniqueEqIndex;

      BackendDAE.ExtraInfo ei;

    case (BackendDAE.SHARED(knownVars=knvars, externalObjects=extobj,
                            initialEqs=ie, constraints=constrs, classAttrs=clsAttrs, cache=cache, graph=graph,
                            extObjClasses=extObjClasses, functionTree=funcs,  info = ei), _, _, _)
      equation
        // kvars params
        ((parameterEquationsTmp, lv, lkn, lv1, lv2, _)) = BackendVariable.traverseBackendDAEVars(knvars, createInitialParamAssignments, ({}, {}, {}, {}, {}, 1));

        // sort the equations
        emptyeqns = BackendEquation.emptyEqns();
        pe = BackendEquation.listEquation(parameterEquationsTmp);
        alisvars = BackendVariable.emptyVars();
        v = BackendVariable.listVar(lv);
        kn = BackendVariable.listVar(lkn);
        funcs = DAEUtil.avlTreeNew();
        syst = BackendDAE.EQSYSTEM(v, pe, NONE(), NONE(), BackendDAE.NO_MATCHING(), {}, BackendDAE.UNKNOWN_PARTITION());
        shared = BackendDAE.SHARED(kn, extobj, alisvars, emptyeqns, emptyeqns, constrs, clsAttrs, cache, graph, funcs, BackendDAE.EVENT_INFO({}, {}, {}, {}, {}, 0), extObjClasses, BackendDAE.PARAMETERSYSTEM(), {}, ei);
        (syst,_,_) = BackendDAEUtil.getIncidenceMatrixfromOption(syst, BackendDAE.NORMAL(), SOME(funcs));
        v1 = listArray(lv1);
        v2 = listArray(lv2);
        syst = BackendDAEUtil.setEqSystemMatching(syst, BackendDAE.MATCHING(v1, v2, {}));
        (syst, comps) = BackendDAETransform.strongComponents(syst, shared);
        paramdlow = BackendDAE.DAE({syst}, shared);
        if Flags.isSet(Flags.PARAM_DLOW_DUMP) then
          BackendDump.dumpEqnsSolved(paramdlow, "parameters: eqns in order");
        end if;
        (parameterEquations, _, uniqueEqIndex, _) = createEquations(false, false, true, false, syst, shared, comps, iuniqueEqIndex, {});

        ialgs = BackendEquation.traverseEquationArray(ie, traverseAlgorithmFinder, {});
        ialgs = listReverse(ialgs);
        (inalgs, uniqueEqIndex) = List.mapFold(if initialSystemSolved then {} else ialgs, dlowAlgToSimEqSystem, uniqueEqIndex);
        // get minmax and nominal asserts
        varasserts = BackendVariable.traverseBackendDAEVars(knvars, createVarAsserts, {});
        (simvarasserts, uniqueEqIndex) = List.mapFold(varasserts, dlowAlgToSimEqSystem, uniqueEqIndex);

        // do not append the inital algorithms to the parameter equation if the system is solved symbolically
        parameterEquations = listAppend(parameterEquations, listAppend(simvarasserts,inalgs));
        parameterEquations = listAppend(parameterEquations, acc);
      then
        (uniqueEqIndex, parameterEquations);

    else
      equation
        Error.addMessage(Error.INTERNAL_ERROR, {"createParameterEquations failed"});
      then fail();
  end matchcontinue;
end createParameterEquations;

protected function traverseAlgorithmFinder "author: Frenkel TUD 2010-12
  collect all used algorithms"
  input BackendDAE.Equation inEq;
  input list<DAE.Algorithm> inAlgs;
  output BackendDAE.Equation eqn;
  output list<DAE.Algorithm> algs;
algorithm
  (eqn,algs) := matchcontinue (inEq,inAlgs)
    local
      DAE.Algorithm alg;
    case (eqn as BackendDAE.ALGORITHM(alg=alg), algs)
      then (eqn, alg::algs);
    else (inEq,inAlgs);
  end matchcontinue;
end traverseAlgorithmFinder;

protected function createInitialAssignmentsFromStart
  input BackendDAE.Var inVar;
  input tuple<list<BackendDAE.Equation>, BackendDAE.Variables> inTpl;
  output BackendDAE.Var outVar;
  output tuple<list<BackendDAE.Equation>, BackendDAE.Variables> outTpl;
algorithm
  (outVar,outTpl) := matchcontinue (inVar,inTpl)
    local
      BackendDAE.Var var;
      BackendDAE.Equation initialEquation;
      list<BackendDAE.Equation> eqns;
      DAE.ComponentRef name;
      DAE.Exp startv;
      DAE.ElementSource source;
      BackendDAE.Variables av;

      // also add an assignment for variables that have non-constant
      // expressions, e.g. parameter values, as start.  NOTE: such start
      // attributes can then not be changed in the text file, since the initial
      // calc. will override those entries!
    case (var as BackendDAE.VAR(varName=name, source=source), (eqns, av))
      equation
        startv = BackendVariable.varStartValueFail(var);
        false = Expression.isConst(startv);
        SimCodeVar.NOALIAS() = getAliasVar(var, SOME(av));
        initialEquation = BackendDAE.SOLVED_EQUATION(name, startv, source, BackendDAE.EQ_ATTR_DEFAULT_UNKNOWN);
      then (var, (initialEquation :: eqns, av));

    else (inVar,inTpl);
  end matchcontinue;
end createInitialAssignmentsFromStart;

protected function createInitialAssignmentsFromNominal "see also createInitialAssignmentsFromStart"
  input BackendDAE.Var inVar;
  input tuple<list<BackendDAE.Equation>, BackendDAE.Variables> inTpl;
  output BackendDAE.Var outVar;
  output tuple<list<BackendDAE.Equation>, BackendDAE.Variables> outTpl;
algorithm
  (outVar,outTpl) := matchcontinue (inVar,inTpl)
    local
      BackendDAE.Var var;
      BackendDAE.Equation initialEquation;
      list<BackendDAE.Equation> eqns;
      DAE.ComponentRef name;
      DAE.Exp nominalv;
      DAE.ElementSource source;
      BackendDAE.Variables av;

    case (var as BackendDAE.VAR(varName=name, source=source), (eqns, av)) equation
      nominalv = BackendVariable.varNominalValueFail(var);
      false = Expression.isConst(nominalv);
      SimCodeVar.NOALIAS() = getAliasVar(var, SOME(av));
      initialEquation = BackendDAE.SOLVED_EQUATION(name, nominalv, source, BackendDAE.EQ_ATTR_DEFAULT_UNKNOWN);
    then (var, (initialEquation :: eqns, av));

    else (inVar,inTpl);
  end matchcontinue;
end createInitialAssignmentsFromNominal;

protected function createInitialAssignmentsFromMin "see also createInitialAssignmentsFromStart"
  input BackendDAE.Var inVar;
  input tuple<list<BackendDAE.Equation>, BackendDAE.Variables> inTpl;
  output BackendDAE.Var outVar;
  output tuple<list<BackendDAE.Equation>, BackendDAE.Variables> outTpl;
algorithm
  (outVar,outTpl) := matchcontinue (inVar,inTpl)
    local
      BackendDAE.Var var;
      BackendDAE.Equation initialEquation;
      list<BackendDAE.Equation> eqns;
      DAE.ComponentRef name;
      DAE.Exp minv;
      DAE.ElementSource source;
      BackendDAE.Variables av;

    case (var as BackendDAE.VAR(varName=name, source=source), (eqns, av)) equation
      minv = BackendVariable.varMinValueFail(var);
      false = Expression.isConst(minv);
      SimCodeVar.NOALIAS() = getAliasVar(var, SOME(av));
      initialEquation = BackendDAE.SOLVED_EQUATION(name, minv, source, BackendDAE.EQ_ATTR_DEFAULT_UNKNOWN);
    then (var, (initialEquation :: eqns, av));

    else (inVar,inTpl);
  end matchcontinue;
end createInitialAssignmentsFromMin;

protected function createInitialAssignmentsFromMax "see also createInitialAssignmentsFromStart"
  input BackendDAE.Var inVar;
  input tuple<list<BackendDAE.Equation>, BackendDAE.Variables> inTpl;
  output BackendDAE.Var outVar;
  output tuple<list<BackendDAE.Equation>, BackendDAE.Variables> outTpl;
algorithm
  (outVar,outTpl) := matchcontinue (inVar,inTpl)
    local
      BackendDAE.Var var;
      BackendDAE.Equation initialEquation;
      list<BackendDAE.Equation> eqns;
      DAE.ComponentRef name;
      DAE.Exp maxv;
      DAE.ElementSource source;
      BackendDAE.Variables av;

    case (var as BackendDAE.VAR(varName=name, source=source), (eqns, av)) equation
      maxv = BackendVariable.varMaxValueFail(var);
      false = Expression.isConst(maxv);
      SimCodeVar.NOALIAS() = getAliasVar(var, SOME(av));
      initialEquation = BackendDAE.SOLVED_EQUATION(name, maxv, source, BackendDAE.EQ_ATTR_DEFAULT_UNKNOWN);
    then (var, (initialEquation :: eqns, av));

    else (inVar,inTpl);
  end matchcontinue;
end createInitialAssignmentsFromMax;

protected function createInitialParamAssignments
  input BackendDAE.Var inVar;
  input tuple<list<BackendDAE.Equation>, list<BackendDAE.Var>, list<BackendDAE.Var>, list<Integer>, list<Integer>, Integer> inTpl;
  output BackendDAE.Var outVar;
  output tuple<list<BackendDAE.Equation>, list<BackendDAE.Var>, list<BackendDAE.Var>, list<Integer>, list<Integer>, Integer> outTpl;
algorithm
  (outVar,outTpl) := matchcontinue (inVar,inTpl)
    local
      BackendDAE.Var var, var1;
      BackendDAE.Equation initialEquation;
      list<BackendDAE.Equation> eqns;
      DAE.ComponentRef cr;
      DAE.Exp e, cre;
      DAE.ElementSource source;
      list<Integer> v1, v2;
      Integer pos;
      list<BackendDAE.Var> v, kn;
      Boolean b1, b2;

    // ignore constants
    case (var as BackendDAE.VAR(varKind=BackendDAE.CONST()), (eqns, v, kn, v1, v2, pos))
      then (var, (eqns, v, var::kn, v1, v2, pos));

    case (var as BackendDAE.VAR(varName=cr, bindExp=SOME(e), source = source), (eqns, v, kn, v1, v2, pos))
      equation
        false = BackendVariable.isVarOnTopLevelAndInput(var);
        b1 = BackendVariable.isParam(var);
        b2 = Expression.isConstValue(e);
        // if not parameter use it, else use it only if not constant
        true = (not b1) or (b1 and not b2);
        cre = Expression.crefExp(cr);
        initialEquation = BackendDAE.EQUATION(cre, e, source, BackendDAE.EQ_ATTR_DEFAULT_UNKNOWN);
        var1 = BackendVariable.setVarKind(var, BackendDAE.VARIABLE());
      then (var, (initialEquation :: eqns, var1::v, kn, pos::v1, pos::v2, pos+1));
    case (var, (eqns, v, kn, v1, v2, pos))
      equation
        var1 = BackendVariable.setVarKind(var, BackendDAE.PARAM());
      then (var, (eqns, v, var1::kn, v1, v2, pos));
  end matchcontinue;
end createInitialParamAssignments;

protected function createVarAsserts
  input BackendDAE.Var inVar;
  input list<DAE.Algorithm> inAlgs;
  output BackendDAE.Var outVar;
  output list<DAE.Algorithm> outAlgs;
algorithm
  (outVar,outAlgs) := matchcontinue (inVar,inAlgs)
    local
      BackendDAE.Var var;
      list<DAE.Algorithm> asserts, asserts1, asserts2;
      DAE.ComponentRef name;
      DAE.ElementSource source;
      BackendDAE.VarKind kind;
      Option<DAE.VariableAttributes> attr;

    case (var as BackendDAE.VAR(), asserts)
      equation
        (_, asserts1) = createVarMinMaxAssert(var, asserts);
        (_, asserts2) = createVarNominalAssert(var, asserts1);
      then (var, asserts2);

    else (inVar,inAlgs);
  end matchcontinue;
end createVarAsserts;

protected function createVarNominalAssert
  input BackendDAE.Var inVar;
  input list<DAE.Algorithm> inAsserts;
  output BackendDAE.Var outVar;
  output list<DAE.Algorithm> asserts;
algorithm
  (outVar,asserts) := matchcontinue (inVar,inAsserts)
    local
      BackendDAE.Var var;
      DAE.ComponentRef name;
      DAE.ElementSource source;
      BackendDAE.VarKind kind;
      Option<DAE.VariableAttributes> attr;
      BackendDAE.Type varType;

    case (var as BackendDAE.VAR(varName=name, varKind=kind, values = attr, varType=varType, source = source), asserts)
      equation
        asserts = BackendVariable.getNominalAssert(attr, name, source, kind, varType, asserts);
      then (var, asserts);

    else (inVar,inAsserts);
  end matchcontinue;
end createVarNominalAssert;

protected function createVarMinMaxAssert
  input BackendDAE.Var inVar;
  input list<DAE.Algorithm> inAsserts;
  output BackendDAE.Var outVar;
  output list<DAE.Algorithm> asserts;
algorithm
  (outVar,asserts) := matchcontinue (inVar,inAsserts)
    local
      BackendDAE.Var var;
      DAE.ComponentRef name;
      DAE.ElementSource source;
      BackendDAE.VarKind kind;
      Option<DAE.VariableAttributes> attr;
      BackendDAE.Type varType;

    case (var as BackendDAE.VAR(varName=name, varKind=kind, values = attr, varType=varType, source = source), asserts)
      equation
        asserts = BackendVariable.getMinMaxAsserts(attr, name, source, kind, varType, asserts);
      then (var, asserts);

    else (inVar,inAsserts);
  end matchcontinue;
end createVarMinMaxAssert;

public function createModelInfo
  input Absyn.Path class_;
  input BackendDAE.BackendDAE dlow;
  input list<SimCode.Function> functions;
  input list<String> labels;
  input Integer numInitialEquations;
  input Integer numInitialAlgorithms;
  input Integer numStateSets;
  input String fileDir;
  output SimCode.ModelInfo modelInfo;
algorithm
  modelInfo :=
  matchcontinue (class_, dlow, functions, labels, numInitialEquations, numInitialAlgorithms, numStateSets, fileDir)
    local
      String description,directory;
      SimCode.VarInfo varInfo;
      SimCodeVar.SimVars vars;
      list<SimCodeVar.SimVar> stateVars;
      list<SimCodeVar.SimVar> derivativeVars;
      list<SimCodeVar.SimVar> algVars;
      list<SimCodeVar.SimVar> discreteAlgVars;
      list<SimCodeVar.SimVar> intAlgVars;
      list<SimCodeVar.SimVar> boolAlgVars;
      list<SimCodeVar.SimVar> inputVars;
      list<SimCodeVar.SimVar> outputVars;
      list<SimCodeVar.SimVar> aliasVars;
      list<SimCodeVar.SimVar> intAliasVars;
      list<SimCodeVar.SimVar> boolAliasVars;
      list<SimCodeVar.SimVar> paramVars;
      list<SimCodeVar.SimVar> intParamVars;
      list<SimCodeVar.SimVar> boolParamVars;
      list<SimCodeVar.SimVar> stringAlgVars;
      list<SimCodeVar.SimVar> stringParamVars;
      list<SimCodeVar.SimVar> stringAliasVars;
      list<SimCodeVar.SimVar> extObjVars;
      list<SimCodeVar.SimVar> constVars;
      list<SimCodeVar.SimVar> intConstVars;
      list<SimCodeVar.SimVar> boolConstVars;
      list<SimCodeVar.SimVar> stringConstVars;
      list<SimCodeVar.SimVar> jacobianVars;
      list<SimCodeVar.SimVar> realOptimizeConstraintsVars;
      list<SimCodeVar.SimVar> realOptimizeFinalConstraintsVars;
      Integer nx, ny, ndy, np, na, next, numOutVars, numInVars, ny_int, np_int, na_int, ny_bool, np_bool, dim_1, dim_2, numOptimizeConstraints, numOptimizeFinalConstraints;
      Integer na_bool, ny_string, np_string, na_string;
      list<SimCodeVar.SimVar> states1, states_lst, states_lst2, der_states_lst;
      list<SimCodeVar.SimVar> states_2, derivatives_2;


    case (_, _, _, _, _, _, _, _)
      equation
        // name = Absyn.pathStringNoQual(class_);
        directory = System.trim(fileDir, "\"");
        vars = createVars(dlow);
        SimCodeVar.SIMVARS(stateVars=stateVars, algVars=algVars, discreteAlgVars=discreteAlgVars, intAlgVars=intAlgVars, boolAlgVars=boolAlgVars,
                inputVars=inputVars, outputVars=outputVars, aliasVars=aliasVars, intAliasVars=intAliasVars, boolAliasVars=boolAliasVars,
                paramVars=paramVars, intParamVars=intParamVars, boolParamVars=boolParamVars, stringAlgVars=stringAlgVars,
                stringParamVars=stringParamVars, stringAliasVars=stringAliasVars, extObjVars=extObjVars,
                    realOptimizeConstraintsVars=realOptimizeConstraintsVars, realOptimizeFinalConstraintsVars= realOptimizeFinalConstraintsVars) = vars;
        BackendDAE.DAE(shared=BackendDAE.SHARED(info=BackendDAE.EXTRA_INFO(description=description))) = dlow;
        nx = listLength(stateVars);
        ny = listLength(algVars);
        ndy = listLength(discreteAlgVars);
        ny_int = listLength(intAlgVars);
        ny_bool = listLength(boolAlgVars);
        numOutVars = listLength(outputVars);
        numInVars = listLength(inputVars);
        na = listLength(aliasVars);
        na_int = listLength(intAliasVars);
        na_bool = listLength(boolAliasVars);
        np = listLength(paramVars);
        np_int = listLength(intParamVars);
        np_bool = listLength(boolParamVars);
        ny_string = listLength(stringAlgVars);
        np_string = listLength(stringParamVars);
        na_string = listLength(stringAliasVars);
        next = listLength(extObjVars);
        numOptimizeConstraints =  listLength(realOptimizeConstraintsVars);
        numOptimizeFinalConstraints = listLength(realOptimizeFinalConstraintsVars);
        varInfo = createVarInfo(dlow, nx, ny, ndy, np, na, next, numOutVars, numInVars, numInitialEquations, numInitialAlgorithms,
                 ny_int, np_int, na_int, ny_bool, np_bool, na_bool, ny_string, np_string, na_string, numStateSets, numOptimizeConstraints, numOptimizeFinalConstraints);
      then
        SimCode.MODELINFO(class_, description, directory, varInfo, vars, functions, labels);

    else
      equation
        Error.addInternalError("createModelInfo failed", sourceInfo());
      then
        fail();
  end matchcontinue;
end createModelInfo;


protected function createVarInfo
  input BackendDAE.BackendDAE dlow;
  input Integer nx;
  input Integer ny;
  input Integer ndy;
  input Integer np;
  input Integer na;
  input Integer next;
  input Integer numOutVars;
  input Integer numInVars;
  input Integer numInitialEquations;
  input Integer numInitialAlgorithms;
  input Integer ny_int;
  input Integer np_int;
  input Integer na_int;
  input Integer ny_bool;
  input Integer np_bool;
  input Integer na_bool;
  input Integer ny_string;
  input Integer np_string;
  input Integer na_string;
  input Integer numStateSets;
  input Integer numOptimizeConstraints;
  input Integer numOptimizeFinalConstraints;
  output SimCode.VarInfo varInfo;
protected
  Integer numZeroCrossings, numTimeEvents, numRelations, numMathEventFunctions, numInitialResiduals, nDiscreteReal;
algorithm
  (numZeroCrossings, numTimeEvents, numRelations, numMathEventFunctions) := BackendDAEUtil.numberOfZeroCrossings(dlow);
  numZeroCrossings := filterNg(numZeroCrossings);
  numTimeEvents := filterNg(numTimeEvents);
  numRelations := filterNg(numRelations);
  numInitialResiduals := numInitialEquations+numInitialAlgorithms;
  varInfo := SimCode.VARINFO(numZeroCrossings, numTimeEvents, numRelations, numMathEventFunctions, nx, ny, ndy, ny_int, ny_bool, na, na_int, na_bool, np, np_int, np_bool, numOutVars, numInVars,
          numInitialEquations, numInitialAlgorithms, numInitialResiduals, next, ny_string, np_string, na_string, 0, 0, 0, 0, numStateSets,0,numOptimizeConstraints, numOptimizeFinalConstraints);
end createVarInfo;

protected function createVars
  input BackendDAE.BackendDAE dlow;
  output SimCodeVar.SimVars varsOut;
algorithm
  varsOut :=
  match (dlow)
    local
      BackendDAE.Variables knvars;
      BackendDAE.Variables extvars;
      BackendDAE.EquationArray ie;
      BackendDAE.Variables aliasVars;
      BackendDAE.EqSystems systs;
    case (BackendDAE.DAE(eqs=systs, shared=BackendDAE.SHARED(
      knownVars = knvars,
      externalObjects = extvars,
      aliasVars = aliasVars)))
      equation
        /* Extract from variable list */
        ((varsOut, _, _)) = List.fold1(List.map(systs, BackendVariable.daeVars), BackendVariable.traverseBackendDAEVars, extractVarsFromList, (SimCodeVar.emptySimVars, aliasVars, knvars));
        /* Extract from known variable list */
        ((varsOut, _, _)) = BackendVariable.traverseBackendDAEVars(knvars, extractVarsFromList, (varsOut, aliasVars, knvars));
        /* Extract from removed variable list */
        ((varsOut, _, _)) = BackendVariable.traverseBackendDAEVars(aliasVars, extractVarsFromList, (varsOut, aliasVars, knvars));
        /* Extract from external object list */
        ((varsOut, _, _)) = BackendVariable.traverseBackendDAEVars(extvars, extractVarsFromList, (varsOut, aliasVars, knvars));
        /* sort variables on index */
        varsOut = sortSimvars(varsOut);
        varsOut = if stringEqual(Config.simCodeTarget(), "Cpp") then extendIncompleteArray(varsOut) else varsOut;
        /* Index of algebraic and parameters need
         to fix due to separation of int Vars*/
        varsOut = fixIndex(varsOut);
        varsOut = setVariableIndex(varsOut);
      then
        varsOut;

  end match;
end createVars;

protected function setRecordVariability"evaluates if all scalar record values are parameter
author:Waurich TUD 2014-09"
  input list<DAE.Function> funcsIn;
  input BackendDAE.BackendDAE dae;
  output list<DAE.Function> funcsOut;
protected
  BackendDAE.Shared shared;
  BackendDAE.Variables knVars;
  DAE.FunctionTree functionTree;
  list<DAE.Function> funcs, records;
  list<BackendDAE.Var> recVars, params;
  list<Absyn.Path> paths;
algorithm
  BackendDAE.DAE(shared=shared) := dae;
  BackendDAE.SHARED(knownVars=knVars) := shared;

  recVars := List.filterOnTrue(BackendVariable.varList(knVars),BackendVariable.isRecordVar);
  paths := List.map(recVars,getVarRecordPath);
  funcsOut := setRecordVariability2(funcsIn,recVars,paths,{});  //are all scalars parameters? if so set varKind to PARAM()
end setRecordVariability;

protected function setRecordVariability2"traverses all DAE.Function and updates the varKind of a RECORD_CONSTRUCTOR for parameter records
author:Waurich TUD 2014-09"
  input list<DAE.Function> funcsIn;
  input list<BackendDAE.Var> recVarsIn;
  input list<Absyn.Path> pathsIn;
  input list<DAE.Function> funcFold;
  output list<DAE.Function> funcOut;
algorithm
  funcOut := matchcontinue(funcsIn,recVarsIn,pathsIn,funcFold)
    local
      Integer numScalars;
      list<Boolean> bLst;
      list<BackendDAE.Var> vars;
      Absyn.Path path;
      list<Absyn.Path> paths;
      DAE.ElementSource source;
      DAE.Function rec, func;
      DAE.Type ty;
      list<DAE.Function> rest;
      list<DAE.ComponentRef> expandedCrefs;
      list<DAE.Var> recScalars;
      list<DAE.FuncArg> args;
    case({},_,_,_)
      then listReverse(funcFold);
    case((rec as DAE.RECORD_CONSTRUCTOR(path=path,type_= ty,source=source))::rest,_,_,_)
      equation
       DAE.T_FUNCTION(funcArg=args) = ty;
       numScalars = List.fold(List.map(args,DAEUtil.funcArgDim),intAdd,0);
       bLst = List.map1(pathsIn,Absyn.pathEqual,path);
       (_,vars) = List.filter1OnTrueSync(bLst,boolEq,true,recVarsIn);  // all vars that have the same record path
       true = intEq(listLength(vars),numScalars);
       vars = List.filterOnTrue(vars,BackendVariable.isParam);// all record vars that are parameters
       true = intEq(listLength(vars),numScalars) and intNe(numScalars,0);
       rec = DAE.RECORD_CONSTRUCTOR(path,ty,source,DAE.PARAM());
      then setRecordVariability2(rest,recVarsIn,pathsIn,rec::funcFold);
    else
      equation
        func::rest = funcsIn;
      then setRecordVariability2(rest,recVarsIn,pathsIn,func::funcFold);
  end matchcontinue;
end setRecordVariability2;

protected function getVarRecordPath"gets the path for the record, if any of the crefId from the var is a recordtype, otherwise NONE()
author:Waurich TUD 2014-09"
  input BackendDAE.Var var;
  output Absyn.Path path;
protected
  list<Boolean> bLst;
  DAE.ComponentRef cref;
  DAE.ElementSource source;
  list<Absyn.Path> paths;
algorithm
  BackendDAE.VAR(varName=cref, source=source) := var;
  _::paths := DAEUtil.getElementSourceTypes(source);
  path := getRecordPathFromCref(cref,paths);
  bLst := List.map1(paths,Absyn.pathEqual,path);
  (_,paths) := List.filter1OnTrueSync(bLst,boolEq,true,paths);
  if listLength(paths)<>1 then
    print("SimCodeUtil.getVarRecordPath could not found a unique path for the record constructor\n");
  end if;
  path := List.first(paths);
end getVarRecordPath;

protected function getRecordPathFromCref"gets the path if any crefID is a recordtype, otherwise NONE()
author:Waurich TUD 2014-09"
  input DAE.ComponentRef crefIn;
  input list<Absyn.Path> pathsIn;
  output Absyn.Path pathOut;
algorithm
  pathOut := matchcontinue(crefIn,pathsIn)
    local
      Absyn.Path path;
      list<Absyn.Path> rest;
      DAE.ComponentRef cref;
    case(DAE.CREF_IDENT(identType=DAE.T_COMPLEX(complexClassType = ClassInf.RECORD(_))),path::_)
      then path;
    case(DAE.CREF_QUAL(identType=DAE.T_COMPLEX(complexClassType = ClassInf.RECORD(_))),path::_)
      then path;
    case(DAE.CREF_QUAL(ident = "$DER", componentRef = cref),_)
      then getRecordPathFromCref(cref, pathsIn);
    case(DAE.CREF_QUAL(componentRef=cref),_::rest)
      then getRecordPathFromCref(cref,rest);
    else
      equation
        print("getRecordPathFromCref failed for "+ComponentReference.debugPrintComponentRefTypeStr(crefIn)+"\n");
        then fail();
  end matchcontinue;
end getRecordPathFromCref;

protected function extractVarsFromList
  input BackendDAE.Var inVar;
  input tuple<SimCodeVar.SimVars, BackendDAE.Variables, BackendDAE.Variables> inTpl;
  output BackendDAE.Var outVar;
  output tuple<SimCodeVar.SimVars, BackendDAE.Variables, BackendDAE.Variables> outTpl;
algorithm
  (outVar,outTpl) := matchcontinue (inVar,inTpl)
    local
      BackendDAE.Var var;
      SimCodeVar.SimVars vars;
      BackendDAE.Variables aliasVars, v;
    case (var, (vars, aliasVars, v))
      equation
        vars = extractVarFromVar(var, aliasVars, v, vars);
      then (var, (vars, aliasVars, v));
    else (inVar,inTpl);
  end matchcontinue;
end extractVarsFromList;

// one dlow var can result in multiple simvars: input and output are a subset
// of algvars for example
protected function extractVarFromVar
  input BackendDAE.Var dlowVar;
  input BackendDAE.Variables inAliasVars;
  input BackendDAE.Variables inVars;
  input SimCodeVar.SimVars varsIn;
  output SimCodeVar.SimVars varsOut;
algorithm
  varsOut :=
  match (dlowVar, inAliasVars, inVars, varsIn)
    local
      list<SimCodeVar.SimVar> stateVars;
      list<SimCodeVar.SimVar> derivativeVars;
      list<SimCodeVar.SimVar> algVars;
      list<SimCodeVar.SimVar> discreteAlgVars;
      list<SimCodeVar.SimVar> intAlgVars;
      list<SimCodeVar.SimVar> boolAlgVars;
      list<SimCodeVar.SimVar> inputVars;
      list<SimCodeVar.SimVar> outputVars;
      list<SimCodeVar.SimVar> aliasVars;
      list<SimCodeVar.SimVar> intAliasVars;
      list<SimCodeVar.SimVar> boolAliasVars;
      list<SimCodeVar.SimVar> paramVars;
      list<SimCodeVar.SimVar> intParamVars;
      list<SimCodeVar.SimVar> boolParamVars;
      list<SimCodeVar.SimVar> stringAlgVars;
      list<SimCodeVar.SimVar> stringParamVars;
      list<SimCodeVar.SimVar> stringAliasVars;
      list<SimCodeVar.SimVar> extObjVars;
      list<SimCodeVar.SimVar> constVars;
      list<SimCodeVar.SimVar> intConstVars;
      list<SimCodeVar.SimVar> boolConstVars;
      list<SimCodeVar.SimVar> stringConstVars;
      list<SimCodeVar.SimVar> jacobianVars;
      list<SimCodeVar.SimVar> realOptimizeConstraintsVars;
      list<SimCodeVar.SimVar> realOptimizeFinalConstraintsVars;
      SimCodeVar.SimVar simvar;
      SimCodeVar.SimVar derivSimvar;
      BackendDAE.Variables v;
      Boolean isalias;
    case (_, _, v,
      SimCodeVar.SIMVARS(stateVars, derivativeVars, algVars, discreteAlgVars, intAlgVars, boolAlgVars, inputVars, outputVars,
          aliasVars, intAliasVars, boolAliasVars, paramVars, intParamVars, boolParamVars,
          stringAlgVars, stringParamVars, stringAliasVars, extObjVars, constVars, intConstVars, boolConstVars, stringConstVars, jacobianVars, realOptimizeConstraintsVars, realOptimizeFinalConstraintsVars))
      equation
        /* extract the sim var */
        simvar = dlowvarToSimvar(dlowVar, SOME(inAliasVars), v);
        derivSimvar = derVarFromStateVar(simvar);
        isalias = isAliasVar(simvar);
        /* figure out in which lists to put it */
        stateVars = List.consOnTrue((not isalias) and
          BackendVariable.isStateVar(dlowVar), simvar, stateVars);
        derivativeVars = List.consOnTrue((not isalias) and
          BackendVariable.isStateVar(dlowVar), derivSimvar, derivativeVars);
        algVars = List.consOnTrue((not isalias) and
          BackendVariable.isVarNonDiscreteAlg(dlowVar), simvar, algVars);
        discreteAlgVars = List.consOnTrue((not isalias) and
          BackendVariable.isVarDiscreteAlg(dlowVar), simvar, discreteAlgVars);
        intAlgVars = List.consOnTrue((not isalias) and
          BackendVariable.isVarIntAlg(dlowVar), simvar, intAlgVars);
        boolAlgVars = List.consOnTrue((not isalias) and
          BackendVariable.isVarBoolAlg(dlowVar), simvar, boolAlgVars);
        inputVars = List.consOnTrue((not isalias) and
          BackendVariable.isVarOnTopLevelAndInput(dlowVar), simvar, inputVars);
        outputVars = List.consOnTrue((not isalias) and
          BackendVariable.isVarOnTopLevelAndOutput(dlowVar), simvar, outputVars);
        paramVars = List.consOnTrue((not isalias) and
          BackendVariable.isVarParam(dlowVar), simvar, paramVars);
        intParamVars = List.consOnTrue((not isalias) and
          BackendVariable.isVarIntParam(dlowVar), simvar, intParamVars);
        boolParamVars = List.consOnTrue((not isalias) and
          BackendVariable.isVarBoolParam(dlowVar), simvar, boolParamVars);
        stringAlgVars = List.consOnTrue((not isalias) and
          BackendVariable.isVarStringAlg(dlowVar), simvar, stringAlgVars);
        stringParamVars = List.consOnTrue((not isalias) and
          BackendVariable.isVarStringParam(dlowVar), simvar, stringParamVars);
        extObjVars = List.consOnTrue((not isalias) and
          BackendVariable.isExtObj(dlowVar), simvar, extObjVars);
        aliasVars = List.consOnTrue( isalias and
          BackendVariable.isVarNonDiscreteAlg(dlowVar), simvar, aliasVars);
        intAliasVars = List.consOnTrue( isalias and
          BackendVariable.isVarIntAlg(dlowVar), simvar, intAliasVars);
        boolAliasVars = List.consOnTrue( isalias and
          BackendVariable.isVarBoolAlg(dlowVar), simvar, boolAliasVars);
        stringAliasVars = List.consOnTrue( isalias and
          BackendVariable.isVarStringAlg(dlowVar), simvar, stringAliasVars);
        constVars =List.consOnTrue((not isalias) and
          BackendVariable.isVarConst(dlowVar), simvar, constVars);
        intConstVars = List.consOnTrue((not isalias) and
          BackendVariable.isVarIntConst(dlowVar), simvar, intConstVars);
        boolConstVars = List.consOnTrue((not isalias) and
          BackendVariable.isVarBoolConst(dlowVar), simvar, boolConstVars);
        stringConstVars = List.consOnTrue((not isalias) and
          BackendVariable.isVarStringConst(dlowVar), simvar, stringConstVars);
        realOptimizeConstraintsVars = List.consOnTrue((not isalias) and
          BackendVariable.isRealOptimizeConstraintsVars(dlowVar), simvar, realOptimizeConstraintsVars);
        realOptimizeFinalConstraintsVars = List.consOnTrue((not isalias) and
          BackendVariable.isRealOptimizeFinalConstraintsVars(dlowVar), simvar, realOptimizeFinalConstraintsVars);
      then
        SimCodeVar.SIMVARS(stateVars, derivativeVars, algVars, discreteAlgVars, intAlgVars, boolAlgVars, inputVars, outputVars,
          aliasVars, intAliasVars, boolAliasVars, paramVars, intParamVars, boolParamVars,
          stringAlgVars, stringParamVars, stringAliasVars, extObjVars, constVars, intConstVars, boolConstVars, stringConstVars, jacobianVars, realOptimizeConstraintsVars, realOptimizeFinalConstraintsVars);
  end match;
end extractVarFromVar;

protected function derVarFromStateVar
  input SimCodeVar.SimVar state;
  output SimCodeVar.SimVar deriv;
algorithm
  deriv :=
  match (state)
    local
      DAE.ComponentRef name;
      BackendDAE.VarKind kind;
      String comment, unit, displayUnit;
      Integer index;
      Option<DAE.Exp> minVal, maxVal;
      Option<DAE.Exp> initVal, nomVal;
      Boolean isFixed, isProtected;
      DAE.Type type_;
      Boolean isDiscrete, isValueChangeable;
      DAE.ComponentRef arrayCref;
      DAE.ElementSource source;
      list<String> numArrayElement;
    case (SimCodeVar.SIMVAR(name, _, comment, unit, displayUnit, index, minVal, maxVal, _, nomVal, isFixed, type_, isDiscrete, NONE(), _, source, _, NONE(), numArrayElement, _, isProtected))
      equation
        name = ComponentReference.crefPrefixDer(name);
      then
        SimCodeVar.SIMVAR(name, BackendDAE.STATE_DER(), comment, unit, displayUnit, index, minVal, maxVal, NONE(), nomVal, isFixed, type_, isDiscrete, NONE(), SimCodeVar.NOALIAS(), source, SimCodeVar.INTERNAL(), NONE(), numArrayElement, false, isProtected);
    case (SimCodeVar.SIMVAR(name, _, comment, unit, displayUnit, index, minVal, maxVal, _, nomVal, isFixed, type_, isDiscrete, SOME(arrayCref), _, source, _, NONE(), numArrayElement, _, isProtected))
      equation
        name = ComponentReference.crefPrefixDer(name);
        arrayCref = ComponentReference.crefPrefixDer(arrayCref);
      then
        SimCodeVar.SIMVAR(name, BackendDAE.STATE_DER(), comment, unit, displayUnit, index, minVal, maxVal, NONE(), nomVal, isFixed, type_, isDiscrete, SOME(arrayCref), SimCodeVar.NOALIAS(), source, SimCodeVar.INTERNAL(), NONE(), numArrayElement, false, isProtected);
  end match;
end derVarFromStateVar;


public function dumpVar
  input SimCodeVar.SimVar inVar;
algorithm
  _ := match(inVar)
  local
    Integer i;
    DAE.ComponentRef name, name2;
    SimCodeVar.AliasVariable aliasvar;
    String s1, s2;
    case (SimCodeVar.SIMVAR(name= name, aliasvar = SimCodeVar.NOALIAS(), index = i))
    equation
        s1 = ComponentReference.printComponentRefStr(name);
        print(" No Alias for var : " + s1 + " index: "+intString(i)+ "\n");
     then ();
    case (SimCodeVar.SIMVAR(name= name, aliasvar = SimCodeVar.ALIAS(varName = name2)))
    equation
        s1 = ComponentReference.printComponentRefStr(name);
        s2 = ComponentReference.printComponentRefStr(name2);
        print(" Alias for var " + s1 + " is " + s2 + "\n");
    then ();
    case (SimCodeVar.SIMVAR(name= name, aliasvar = SimCodeVar.NEGATEDALIAS(varName = name2)))
    equation
        s1 = ComponentReference.printComponentRefStr(name);
        s2 = ComponentReference.printComponentRefStr(name2);
        print(" Minus Alias for var " + s1 + " is " + s2 + "\n");
     then ();
   end match;
end dumpVar;

protected function dumpVarLst"dumps a list of SimVars to stdout.
author:Waurich TUD 2014-05"
  input list<SimCodeVar.SimVar> varLst;
  input String header;
algorithm
  if List.isNotEmpty(varLst) then
    print(header+":\n");
    print("----------------------\n");
    List.map_0(varLst,dumpVar);
    print("\n");
  end if;
end dumpVarLst;

protected function dumpVariablesString "dumps a list of SimCode.Variables to stdout.
author: Waurich TUD 2014-09"
  input list<SimCode.Variable> vars;
  input String delimiter;
algorithm
  _ := match(vars,delimiter)
    local
      String s1,s2;
      DAE.ComponentRef cref;
      DAE.Type ty;
      DAE.VarKind kind;
      Option<DAE.Exp> val;
      list<DAE.Exp> instDims;
      list<SimCode.Variable> rest;
    case({},_)
      equation
        then();
    case(SimCode.VARIABLE(name=cref,ty=ty,kind=kind)::rest,_)
      equation
        (s1,_) = DAEDump.printTypeStr(ty);
        s1 = Types.printTypeStr(ty);
        s2 = DAEDump.dumpKindStr(kind);
        print(ComponentReference.printComponentRefStr(cref)+" ("+s1+", "+s2+") "+delimiter);
        dumpVariablesString(rest,delimiter);
      then ();
  end match;
end dumpVariablesString;

public function dumpModelInfo"dumps the SimVars to stdout
author:Waurich TUD 2014-05"
  input SimCode.ModelInfo modelInfo;
protected
  Integer nsv,nalgv;
  SimCode.VarInfo varInfo;
  SimCodeVar.SimVars simVars;
  list<SimCodeVar.SimVar> stateVars;
  list<SimCodeVar.SimVar> derivativeVars;
  list<SimCodeVar.SimVar> algVars;
  list<SimCodeVar.SimVar> discreteAlgVars;
  list<SimCodeVar.SimVar> paramVars;
  list<SimCodeVar.SimVar> intParamVars;
  list<SimCodeVar.SimVar> constVars;
  list<SimCodeVar.SimVar> intConstVars;
  list<SimCodeVar.SimVar> stringConstVars;
  list<SimCode.Function> functions;
algorithm
  SimCode.MODELINFO(vars=simVars, varInfo=varInfo, functions=functions) := modelInfo;
  SimCodeVar.SIMVARS(stateVars=stateVars,derivativeVars=derivativeVars,algVars=algVars,discreteAlgVars=discreteAlgVars,paramVars=paramVars,intParamVars=intParamVars, constVars=constVars,intConstVars=intConstVars,stringConstVars=stringConstVars) := simVars;
  SimCode.VARINFO(numStateVars=nsv,numAlgVars=nalgv) := varInfo;
  dumpVarLst(stateVars,"stateVars ("+intString(nsv)+")");
  dumpVarLst(derivativeVars,"derivativeVars");
  dumpVarLst(algVars,"algVars ("+intString(nalgv)+")");
  dumpVarLst(discreteAlgVars,"discreteAlgVars");
  dumpVarLst(paramVars,"paramVars");
  dumpVarLst(intParamVars,"intParamVars");
  dumpVarLst(constVars,"constVars");
  dumpVarLst(intConstVars,"intConstVars");
  dumpVarLst(stringConstVars,"stringConstVars");
  print("functions:\n-----------\n\n");
  dumpFunctions(functions);
end dumpModelInfo;

protected function dumpFunctions
  input list<SimCode.Function> functions;
algorithm
  _ := match(functions)
  local
    Absyn.Path path;
    list<SimCode.Function> rest;
    list<SimCode.Variable> outVars,functionArguments,variableDeclarations,funArgs, locals;
    list<SimCode.Statement> body;
  case({})
    equation
    then ();
  case(SimCode.FUNCTION(name=path,outVars=outVars,functionArguments=functionArguments,variableDeclarations=variableDeclarations)::rest)
    equation
      print("Function: "+Absyn.pathStringNoQual(path)+"\n");
      print("\toutVars: ");
      dumpVariablesString(outVars," , ");
      print("\n\tfunctionArguments: ");
      dumpVariablesString(functionArguments," , ");
      print("\n\tvariableDeclarations: ");
      dumpVariablesString(variableDeclarations," , ");
      print("\n");
      dumpFunctions(rest);
    then ();
  case(SimCode.PARALLEL_FUNCTION(name=path)::rest)
    equation
      print("Parallel Function: "+Absyn.pathStringNoQual(path)+"\n");
      dumpFunctions(rest);
    then ();
  case(SimCode.KERNEL_FUNCTION(name=path)::rest)
    equation
      print("Kernel Function: "+Absyn.pathStringNoQual(path)+"\n");
      dumpFunctions(rest);
    then ();
  case(SimCode.EXTERNAL_FUNCTION(name=path)::rest)
    equation
      print("External Function: "+Absyn.pathStringNoQual(path)+"\n");
      dumpFunctions(rest);
    then ();
  case(SimCode.RECORD_CONSTRUCTOR(name=path, funArgs=funArgs, locals=locals)::rest)
    equation
      print("Record: "+Absyn.pathStringNoQual(path)+"\n");
      print("\tfunArgs: ");
      dumpVariablesString(funArgs," , ");
      print("\n\tlocals: ");
      dumpVariablesString(locals," , ");
      print("\n");
      dumpFunctions(rest);
    then ();
  end match;
end dumpFunctions;

public function dumpSimEqSystemLst
  input list<SimCode.SimEqSystem> eqSysLstIn;
  output String sOut;
protected
  list<String> sLst;
algorithm
  sLst := List.map(eqSysLstIn,dumpSimEqSystem);
  sLst := List.map1(sLst,stringAppend,"\n");
  sOut := List.fold(sLst,stringAppend,"");
end dumpSimEqSystemLst;


public function dumpSimEqSystem "dumps a string of the given SimEqSystem. NOT YET FINISHED.FEEL FREE TO BUILD THE MISSING STRINGS
author:Waurich TUD 2013-11"
  input SimCode.SimEqSystem eqSysIn;
  output String outString;
algorithm
  outString := match(eqSysIn)
    local
      Boolean partMixed,lin,initCall;
      Integer idx,idxLS,idxNLS,idxMS;
      String s;
      list<String> sLst;
      DAE.Exp exp,right;
      DAE.ElementSource source;
      DAE.ComponentRef cref,left;
      SimCode.SimEqSystem cont;
      list<DAE.ComponentRef> crefs,conds;
      list<DAE.Statement> stmts;
      list<SimCode.SimEqSystem> elsebranch,discEqs,eqs,residual;
      list<SimCodeVar.SimVar> vars,discVars;
      list<DAE.Exp> beqs;
      list<tuple<DAE.Exp,list<SimCode.SimEqSystem>>> ifbranches;
      list<tuple<Integer, Integer, SimCode.SimEqSystem>> simJac;
      Option<SimCode.JacobianMatrix> jac;
      Option<SimCode.SimEqSystem> elseWhen;

    case(SimCode.SES_RESIDUAL(index=idx,exp=exp))
      equation
        s = intString(idx) +": "+ ExpressionDump.printExpStr(exp)+" (RESIDUAL)";
    then (s);

    case(SimCode.SES_SIMPLE_ASSIGN(index=idx,cref=cref,exp=exp))
      equation
        s = intString(idx) +": "+ ComponentReference.printComponentRefStr(cref) + "=" + ExpressionDump.printExpStr(exp);
      then (s);

    case(SimCode.SES_ARRAY_CALL_ASSIGN(index=idx,componentRef=cref,exp=exp))
      equation
        s = intString(idx) +": "+ ComponentReference.printComponentRefStr(cref) + "=" + ExpressionDump.printExpStr(exp);
    then (s);

      case(SimCode.SES_IFEQUATION(index=idx))
      equation
        s = intString(idx) +": "+ " (IF)";
        print(s);
    then (s);

    case(SimCode.SES_ALGORITHM(index=idx,statements=stmts))
      equation
        sLst = List.map(stmts,DAEDump.ppStatementStr);
        sLst = List.map1(sLst, stringAppend, "\t");
        s = intString(idx) +": "+ List.fold(sLst,stringAppend,"");
    then (s);

    case(SimCode.SES_LINEAR(index=idx,indexLinearSystem=idxLS, residual=residual, jacobianMatrix=jac, simJac=simJac))
      equation
        s = intString(idx) +": "+ " (LINEAR) index:"+intString(idxLS)+" jacobian: "+boolString(Util.isSome(jac))+"\n";
        s = s+"\t"+stringDelimitList(List.map(residual,dumpSimEqSystem),"\n\t")+"\n";
        eqs = List.map(simJac,Util.tuple33);
        s = s+"\tsimJac:\n"+stringDelimitList(List.map(eqs,dumpSimEqSystem),"\n");
        s = s+dumpJacobianMatrix(jac)+"\n";
    then (s);

    case(SimCode.SES_NONLINEAR(index=idx,indexNonLinearSystem=idxNLS,jacobianMatrix=jac,eqs=eqs, crefs=crefs))
      equation
        s = intString(idx) +": "+ " (NONLINEAR) index:"+intString(idxNLS)+" jacobian: "+boolString(Util.isSome(jac))+"\n";
        s = s +"\t\tcrefs: "+stringDelimitList(List.map(crefs,ComponentReference.debugPrintComponentRefTypeStr)," , ")+"\n";
        s = s + "\t"+stringDelimitList(List.map(eqs,dumpSimEqSystem),"\n\t");
    then (s);

    case(SimCode.SES_MIXED(index=idx,indexMixedSystem=idxMS, cont=cont, discEqs=eqs))
      equation
        s = intString(idx) +": "+ " (MIXED) index:"+intString(idxMS)+"\n";
        s = s+"\t"+dumpSimEqSystem(cont)+"\n";
        s = s+"\tdiscEqs:\n\t"+stringDelimitList(List.map(eqs,dumpSimEqSystem),"\t\n");
    then (s);

    case(SimCode.SES_WHEN(index=idx))
      equation
        s = intString(idx) +": "+ " (WHEN)";
    then (s);
  end match;
end dumpSimEqSystem;

protected function dumpJacobianMatrix
  input Option<SimCode.JacobianMatrix> jacOpt;
  output String sOut;
algorithm
  sOut := match(jacOpt)
    local
      Integer idx;
      String s;
      SimCode.JacobianMatrix jac;
      list<SimCode.JacobianColumn> cols;
      list<SimCode.SimEqSystem> colEqs;
    case(SOME(jac))
      equation
        (cols,_,_,_,_,_,idx) = jac;
        colEqs = List.flatten(List.map(cols,Util.tuple31));
        s = stringDelimitList(List.map(colEqs,dumpSimEqSystem),"\n\t\t");
        s = "jacobian idx: "+intString(idx)+"\n\t"+s;
      then s;
    case(NONE())
      then "";
  end match;
end dumpJacobianMatrix;

public function dumpSimCode
  input SimCode.SimCode simCode;
protected
  Integer nls,nnls,nms,ninite,ninita,ninitr,ne;
  list<SimCode.SimEqSystem> allEquations,jacobianEquations,equationsForZeroCrossings,algorithmAndEquationAsserts,initialEquations,residualEquations,parameterEquations,
  removedInitialEquations,startValueEquations,nominalValueEquations,minValueEquations,maxValueEquations;
  SimCode.ModelInfo modelInfo;
  SimCode.VarInfo varInfo;
  list<list<SimCode.SimEqSystem>> odeEquations, algebraicEquations;
  list<SimCode.JacobianMatrix> jacobianMatrixes;
  list<Option<SimCode.JacobianMatrix>> jacObs;
algorithm
  SimCode.SIMCODE(modelInfo = modelInfo,allEquations = allEquations, odeEquations=odeEquations, algebraicEquations=algebraicEquations,residualEquations=residualEquations, initialEquations=initialEquations, removedInitialEquations=removedInitialEquations,
  startValueEquations=startValueEquations,nominalValueEquations=nominalValueEquations, minValueEquations=minValueEquations, maxValueEquations=maxValueEquations,  algorithmAndEquationAsserts=algorithmAndEquationAsserts, parameterEquations=parameterEquations,
  equationsForZeroCrossings=equationsForZeroCrossings, jacobianEquations=jacobianEquations ,jacobianMatrixes=jacobianMatrixes) := simCode;
  SimCode.MODELINFO(varInfo=varInfo) := modelInfo;
  SimCode.VARINFO(numInitialEquations=ninite,numInitialAlgorithms=ninita,numInitialResiduals=ninitr,numEquations=ne,numLinearSystems=nls,numNonLinearSystems=nnls,numMixedSystems=nms) := varInfo;
  print("allEquations:("+intString(ne)+"),numLS:("+intString(nls)+"),numNLS:("+intString(nnls)+"),numMS:("+intString(nms)+") \n-----------------------\n");
  print(dumpSimEqSystemLst(allEquations)+"\n");
  print("odeEquations ("+intString(listLength(odeEquations))+" systems): \n-----------------------\n");
  print(stringDelimitList(List.map(odeEquations,dumpSimEqSystemLst),"\n--------------\n")+"\n");
  print("algebraicEquations: \n-----------------------\n");
  print(stringDelimitList(List.map(algebraicEquations,dumpSimEqSystemLst),"\n")+"\n");
  print("residualEquations: \n-----------------------\n");
  print(dumpSimEqSystemLst(residualEquations)+"\n");
  print("initialEquations: ("+intString(ninite)+"+"+intString(ninita)+"="+intString(ninitr)+")\n-----------------------\n");
  print(dumpSimEqSystemLst(initialEquations)+"\n");
  print("removedInitialEquations: \n-----------------------\n");
  print(dumpSimEqSystemLst(removedInitialEquations)+"\n");
  print("startValueEquations: \n-----------------------\n");
  print(dumpSimEqSystemLst(startValueEquations)+"\n");
  print("nominalValueEquations: \n-----------------------\n");
  print(dumpSimEqSystemLst(nominalValueEquations)+"\n");
  print("minValueEquations: \n-----------------------\n");
  print(dumpSimEqSystemLst(minValueEquations)+"\n");
  print("maxValueEquations: \n-----------------------\n");
  print(dumpSimEqSystemLst(maxValueEquations)+"\n");
  print("parameterEquations: \n-----------------------\n");
  print(dumpSimEqSystemLst(parameterEquations)+"\n");
  print("algorithmAndEquationAsserts: \n-----------------------\n");
  print(dumpSimEqSystemLst(algorithmAndEquationAsserts)+"\n");
  print("equationsForZeroCrossings: \n-----------------------\n");
  print(dumpSimEqSystemLst(equationsForZeroCrossings)+"\n");
  print("jacobianEquations: \n-----------------------\n");
  print(dumpSimEqSystemLst(jacobianEquations)+"\n");
  print("jacobianMatrixes: \n-----------------------\n");
  jacObs := List.map(jacobianMatrixes,Util.makeOption);
  print(stringDelimitList(List.map(jacObs,dumpJacobianMatrix),"\n")+"\n");
  print("modelInfo: \n-----------------------\n");
  dumpModelInfo(modelInfo);
end dumpSimCode;

protected function isAliasVar
  input SimCodeVar.SimVar var;
  output Boolean res;
algorithm
  res :=
  match (var)
    case (SimCodeVar.SIMVAR(aliasvar=SimCodeVar.NOALIAS()))
    then false;
  else
    then true;
  end match;
end isAliasVar;

protected function sortSimvars
  input SimCodeVar.SimVars unsortedSimvars;
  output SimCodeVar.SimVars sortedSimvars;
algorithm
  sortedSimvars :=
  match (unsortedSimvars)
    local
      list<SimCodeVar.SimVar> stateVars;
      list<SimCodeVar.SimVar> derivativeVars;
      list<SimCodeVar.SimVar> algVars;
      list<SimCodeVar.SimVar> discreteAlgVars;
      list<SimCodeVar.SimVar> intAlgVars;
      list<SimCodeVar.SimVar> boolAlgVars;
      list<SimCodeVar.SimVar> inputVars;
      list<SimCodeVar.SimVar> outputVars;
      list<SimCodeVar.SimVar> aliasVars;
      list<SimCodeVar.SimVar> intAliasVars;
      list<SimCodeVar.SimVar> boolAliasVars;
      list<SimCodeVar.SimVar> paramVars;
      list<SimCodeVar.SimVar> intParamVars;
      list<SimCodeVar.SimVar> boolParamVars;
      list<SimCodeVar.SimVar> stringAlgVars;
      list<SimCodeVar.SimVar> stringParamVars;
      list<SimCodeVar.SimVar> stringAliasVars;
      list<SimCodeVar.SimVar> extObjVars;
      list<SimCodeVar.SimVar> constVars;
      list<SimCodeVar.SimVar> intConstVars;
      list<SimCodeVar.SimVar> boolConstVars;
      list<SimCodeVar.SimVar> stringConstVars;
      list<SimCodeVar.SimVar> jacobianVars;
      list<SimCodeVar.SimVar> realOptimizeConstraintsVars;
      list<SimCodeVar.SimVar> realOptimizeFinalConstraintsVars;
      HashSet.HashSet set;
    case (SimCodeVar.SIMVARS(stateVars, derivativeVars, algVars, discreteAlgVars, intAlgVars, boolAlgVars, inputVars,
      outputVars, aliasVars, intAliasVars, boolAliasVars, paramVars, intParamVars, boolParamVars,
      stringAlgVars, stringParamVars, stringAliasVars, extObjVars, constVars, intConstVars, boolConstVars, stringConstVars, jacobianVars, realOptimizeConstraintsVars,realOptimizeFinalConstraintsVars))
      equation
        stateVars = List.sort(stateVars,simVarCompareByCrefSubsAtEndlLexical);
        derivativeVars = List.sort(derivativeVars,simVarCompareByCrefSubsAtEndlLexical);
        algVars = List.sort(algVars,simVarCompareByCrefSubsAtEndlLexical);
        discreteAlgVars = List.sort(discreteAlgVars,simVarCompareByCrefSubsAtEndlLexical);
        intAlgVars = List.sort(intAlgVars,simVarCompareByCrefSubsAtEndlLexical);
        boolAlgVars = List.sort(boolAlgVars,simVarCompareByCrefSubsAtEndlLexical);
        inputVars = List.sort(inputVars,simVarCompareByCrefSubsAtEndlLexical);
        outputVars = List.sort(outputVars,simVarCompareByCrefSubsAtEndlLexical);
        aliasVars = List.sort(aliasVars,simVarCompareByCrefSubsAtEndlLexical);
        intAliasVars = List.sort(intAliasVars,simVarCompareByCrefSubsAtEndlLexical);
        boolAliasVars = List.sort(boolAliasVars,simVarCompareByCrefSubsAtEndlLexical);
        paramVars = List.sort(paramVars,simVarCompareByCrefSubsAtEndlLexical);
        intParamVars = List.sort(intParamVars,simVarCompareByCrefSubsAtEndlLexical);
        boolParamVars = List.sort(boolParamVars,simVarCompareByCrefSubsAtEndlLexical);
        stringAlgVars = List.sort(stringAlgVars,simVarCompareByCrefSubsAtEndlLexical);
        stringParamVars = List.sort(stringParamVars,simVarCompareByCrefSubsAtEndlLexical);
        stringAliasVars = List.sort(stringAliasVars,simVarCompareByCrefSubsAtEndlLexical);
        extObjVars = List.sort(extObjVars,simVarCompareByCrefSubsAtEndlLexical);
        constVars = List.sort(constVars,simVarCompareByCrefSubsAtEndlLexical);
        intConstVars = List.sort(intConstVars,simVarCompareByCrefSubsAtEndlLexical);
        boolConstVars = List.sort(boolConstVars,simVarCompareByCrefSubsAtEndlLexical);
        stringConstVars = List.sort(stringConstVars,simVarCompareByCrefSubsAtEndlLexical);
        jacobianVars = List.sort(jacobianVars,simVarCompareByCrefSubsAtEndlLexical);
        realOptimizeConstraintsVars = List.sort(realOptimizeConstraintsVars,simVarCompareByCrefSubsAtEndlLexical);
        realOptimizeFinalConstraintsVars = List.sort(realOptimizeFinalConstraintsVars,simVarCompareByCrefSubsAtEndlLexical);
      then SimCodeVar.SIMVARS(stateVars, derivativeVars, algVars, discreteAlgVars, intAlgVars, boolAlgVars, inputVars,
        outputVars, aliasVars, intAliasVars, boolAliasVars, paramVars, intParamVars, boolParamVars,
        stringAlgVars, stringParamVars, stringAliasVars, extObjVars, constVars, intConstVars, boolConstVars, stringConstVars, jacobianVars, realOptimizeConstraintsVars, realOptimizeFinalConstraintsVars);
  end match;
end sortSimvars;

public function simVarCompareByCrefSubsAtEndlLexical
"mahge:
  Compare two simvars by their name. i.e. component ref.
  we use it to make sure elements of a vectorized array stay contagious
  sto each other in the correct offest/order.
  N.B. subs are pushed to end. They are compared if only
  the two crefs' idents are the same"
  input SimCodeVar.SimVar var1;
  input SimCodeVar.SimVar var2;
  output Boolean outBool;
protected
  DAE.ComponentRef cr1;
  DAE.ComponentRef cr2;
algorithm
  cr1 := varName(var1);
  cr2 := varName(var2);
  outBool := ComponentReference.crefLexicalGreaterSubsAtEnd(cr1,cr2);
end simVarCompareByCrefSubsAtEndlLexical;

protected function extendIncompleteArray
   input SimCodeVar.SimVars unsortedSimvars;
  output SimCodeVar.SimVars sortedSimvars;
algorithm
  sortedSimvars :=
  match (unsortedSimvars)
    local
      list<SimCodeVar.SimVar> stateVars;
      list<SimCodeVar.SimVar> derivativeVars;
      list<SimCodeVar.SimVar> algVars;
      list<SimCodeVar.SimVar> discreteAlgVars;
      list<SimCodeVar.SimVar> intAlgVars;
      list<SimCodeVar.SimVar> boolAlgVars;
      list<SimCodeVar.SimVar> inputVars;
      list<SimCodeVar.SimVar> outputVars;
      list<SimCodeVar.SimVar> aliasVars;
      list<SimCodeVar.SimVar> intAliasVars;
      list<SimCodeVar.SimVar> boolAliasVars;
      list<SimCodeVar.SimVar> paramVars;
      list<SimCodeVar.SimVar> intParamVars;
      list<SimCodeVar.SimVar> boolParamVars;
      list<SimCodeVar.SimVar> stringAlgVars;
      list<SimCodeVar.SimVar> stringParamVars;
      list<SimCodeVar.SimVar> stringAliasVars;
      list<SimCodeVar.SimVar> extObjVars;
      list<SimCodeVar.SimVar> constVars;
      list<SimCodeVar.SimVar> intConstVars;
      list<SimCodeVar.SimVar> boolConstVars;
      list<SimCodeVar.SimVar> stringConstVars;
      list<SimCodeVar.SimVar> jacobianVars;
      list<SimCodeVar.SimVar> realOptimizeConstraintsVars;
      list<SimCodeVar.SimVar> realOptimizeFinalConstraintsVars;
      HashSet.HashSet set;

    case (SimCodeVar.SIMVARS(stateVars, derivativeVars, algVars, discreteAlgVars, intAlgVars, boolAlgVars, inputVars,
      outputVars, aliasVars, intAliasVars, boolAliasVars, paramVars, intParamVars, boolParamVars,
      stringAlgVars, stringParamVars, stringAliasVars, extObjVars, constVars, intConstVars, boolConstVars, stringConstVars, jacobianVars,realOptimizeConstraintsVars, realOptimizeFinalConstraintsVars))
      equation
        // for runtime CPP also the incomplete arrays need one special element to generate the array
        // search all arrays with array information
        set = HashSet.emptyHashSet();
        set = List.fold(stateVars, collectArrayFirstVars, set);
        set = List.fold(derivativeVars, collectArrayFirstVars, set);
        set = List.fold(algVars, collectArrayFirstVars, set);
        set = List.fold(discreteAlgVars, collectArrayFirstVars, set);
        set = List.fold(intAlgVars, collectArrayFirstVars, set);
        set = List.fold(boolAlgVars, collectArrayFirstVars, set);
        set = List.fold(inputVars, collectArrayFirstVars, set);
        set = List.fold(outputVars, collectArrayFirstVars, set);
        set = List.fold(aliasVars, collectArrayFirstVars, set);
        set = List.fold(intAliasVars, collectArrayFirstVars, set);
        set = List.fold(boolAliasVars, collectArrayFirstVars, set);
        set = List.fold(paramVars, collectArrayFirstVars, set);
        set = List.fold(intParamVars, collectArrayFirstVars, set);
        set = List.fold(boolParamVars, collectArrayFirstVars, set);
        set = List.fold(stringAlgVars, collectArrayFirstVars, set);
        set = List.fold(stringParamVars, collectArrayFirstVars, set);
        set = List.fold(stringAliasVars, collectArrayFirstVars, set);
        set = List.fold(extObjVars, collectArrayFirstVars, set);
        set = List.fold(constVars, collectArrayFirstVars, set);
        set = List.fold(intConstVars, collectArrayFirstVars, set);
        set = List.fold(boolConstVars, collectArrayFirstVars, set);
        set = List.fold(stringConstVars, collectArrayFirstVars, set);
        set = List.fold(jacobianVars, collectArrayFirstVars, set);
        set = List.fold(realOptimizeConstraintsVars, collectArrayFirstVars, set);
        set = List.fold(realOptimizeFinalConstraintsVars, collectArrayFirstVars, set);
        // add array information to incomplete arrays
        (stateVars, set) = List.mapFold(stateVars, setArrayElementnoFirst, set);
        (derivativeVars, set) = List.mapFold(derivativeVars, setArrayElementnoFirst, set);
        (algVars, set) = List.mapFold(algVars, setArrayElementnoFirst, set);
        (discreteAlgVars, set) = List.mapFold(discreteAlgVars, setArrayElementnoFirst, set);
        (intAlgVars, set) = List.mapFold(intAlgVars, setArrayElementnoFirst, set);
        (boolAlgVars, set) = List.mapFold(boolAlgVars, setArrayElementnoFirst, set);
        (inputVars, set) = List.mapFold(inputVars, setArrayElementnoFirst, set);
        (outputVars, set) = List.mapFold(outputVars, setArrayElementnoFirst, set);
        (aliasVars, set) = List.mapFold(aliasVars, setArrayElementnoFirst, set);
        (intAliasVars, set) = List.mapFold(intAliasVars, setArrayElementnoFirst, set);
        (boolAliasVars, set) = List.mapFold(boolAliasVars, setArrayElementnoFirst, set);
        (paramVars, set) = List.mapFold(paramVars, setArrayElementnoFirst, set);
        (intParamVars, set) = List.mapFold(intParamVars, setArrayElementnoFirst, set);
        (boolParamVars, set) = List.mapFold(boolParamVars, setArrayElementnoFirst, set);
        (stringAlgVars, set) = List.mapFold(stringAlgVars, setArrayElementnoFirst, set);
        (stringParamVars, set) = List.mapFold(stringParamVars, setArrayElementnoFirst, set);
        (stringAliasVars, set) = List.mapFold(stringAliasVars, setArrayElementnoFirst, set);
        (extObjVars, set) = List.mapFold(extObjVars, setArrayElementnoFirst, set);
        (constVars, set) = List.mapFold(constVars, setArrayElementnoFirst, set);
        (intConstVars, set) = List.mapFold(intConstVars, setArrayElementnoFirst, set);
        (boolConstVars, set) = List.mapFold(boolConstVars, setArrayElementnoFirst, set);
        (stringConstVars, set) = List.mapFold(stringConstVars, setArrayElementnoFirst, set);
        (jacobianVars, set) = List.mapFold(jacobianVars, setArrayElementnoFirst, set);
        (realOptimizeConstraintsVars, set) = List.mapFold(realOptimizeConstraintsVars, setArrayElementnoFirst, set);
        (realOptimizeFinalConstraintsVars, set) = List.mapFold(realOptimizeFinalConstraintsVars, setArrayElementnoFirst, set);

      then SimCodeVar.SIMVARS(stateVars, derivativeVars, algVars, discreteAlgVars, intAlgVars, boolAlgVars, inputVars,
        outputVars, aliasVars, intAliasVars, boolAliasVars, paramVars, intParamVars, boolParamVars,
        stringAlgVars, stringParamVars, stringAliasVars, extObjVars, constVars, intConstVars, boolConstVars, stringConstVars, jacobianVars,realOptimizeConstraintsVars, realOptimizeFinalConstraintsVars);

   end match;
end extendIncompleteArray;

protected function setArrayElementnoFirst
"author: Frenkel TUD 2012-10"
  input SimCodeVar.SimVar iVar;
  input HashSet.HashSet iSet;
  output SimCodeVar.SimVar oVar;
  output HashSet.HashSet oSet;
algorithm
  (oVar, oSet) := matchcontinue(iVar, iSet)
    local
      DAE.ComponentRef cr;
      SimCodeVar.SimVar var;
      HashSet.HashSet set;
    case (SimCodeVar.SIMVAR(arrayCref=SOME(_)), _)
      then
       (iVar, iSet);
    case (SimCodeVar.SIMVAR(name=cr, numArrayElement=_::_, arrayCref=NONE()), _)
      equation
        _::_ = ComponentReference.crefLastSubs(cr);
        cr = ComponentReference.crefStripLastSubs(cr);
        false = BaseHashSet.has(cr, iSet);
        var = addSimVarArrayCref(iVar, cr);
        set = BaseHashSet.add(cr, iSet);
      then
       (var, set);
    else (iVar, iSet);
  end matchcontinue;
end setArrayElementnoFirst;

protected function addSimVarArrayCref
"author: Frenkel TUD 2012-10"
  input SimCodeVar.SimVar iVar;
  input DAE.ComponentRef arrayCref;
  output SimCodeVar.SimVar oVar;
algorithm
  oVar := match(iVar, arrayCref)
    local
      DAE.ComponentRef cr;
      BackendDAE.VarKind varKind;
      String comment, unit, displayUnit;
      Integer index;
      Option<DAE.Exp> minValue, maxValue, initialValue, nominalValue;
      Boolean isFixed;
      DAE.Type type_;
      Boolean isDiscrete, isValueChangeable;
      SimCodeVar.AliasVariable aliasvar;
      DAE.ElementSource source;
      SimCodeVar.Causality causality;
      Option<Integer> variable_index;
      list<String> numArrayElement;
      Boolean isProtected;
    case (SimCodeVar.SIMVAR(name=cr, varKind=varKind, comment=comment, unit=unit, displayUnit=displayUnit, index=index,
                         minValue=minValue, maxValue=maxValue, initialValue=initialValue, nominalValue=nominalValue,
                         isFixed=isFixed, type_=type_, isDiscrete=isDiscrete, aliasvar=aliasvar, source=source,
                         causality=causality, variable_index=variable_index, numArrayElement=numArrayElement, isValueChangeable=isValueChangeable, isProtected=isProtected), _)
      then
        SimCodeVar.SIMVAR(cr, varKind, comment, unit, displayUnit, index,
                         minValue, maxValue, initialValue, nominalValue,
                         isFixed, type_, isDiscrete, SOME(arrayCref), aliasvar, source,
                         causality, variable_index, numArrayElement, isValueChangeable, isProtected);
  end match;
end addSimVarArrayCref;

protected function collectArrayFirstVars
"author: Frenkel TUD 2012-10"
  input SimCodeVar.SimVar var;
  input HashSet.HashSet iSet;
  output HashSet.HashSet oSet;
algorithm
  oSet := match(var, iSet)
    local
      DAE.ComponentRef cr;
    case (SimCodeVar.SIMVAR(name=cr, arrayCref=SOME(_)), _)
      equation
        cr = ComponentReference.crefStripLastSubs(cr);
      then
        BaseHashSet.add(cr, iSet);
    else iSet;
  end match;
end collectArrayFirstVars;

protected function fixIndex
  input SimCodeVar.SimVars unfixedSimvars;
  output SimCodeVar.SimVars fixedSimvars;
algorithm
  fixedSimvars := match (unfixedSimvars)
    local
      list<SimCodeVar.SimVar> stateVars;
      list<SimCodeVar.SimVar> derivativeVars;
      list<SimCodeVar.SimVar> algVars;
      list<SimCodeVar.SimVar> discreteAlgVars;
      list<SimCodeVar.SimVar> intAlgVars;
      list<SimCodeVar.SimVar> boolAlgVars;
      list<SimCodeVar.SimVar> inputVars;
      list<SimCodeVar.SimVar> outputVars;
      list<SimCodeVar.SimVar> aliasVars;
      list<SimCodeVar.SimVar> intAliasVars;
      list<SimCodeVar.SimVar> boolAliasVars;
      list<SimCodeVar.SimVar> paramVars;
      list<SimCodeVar.SimVar> intParamVars;
      list<SimCodeVar.SimVar> boolParamVars;
      list<SimCodeVar.SimVar> stringAlgVars;
      list<SimCodeVar.SimVar> stringParamVars;
      list<SimCodeVar.SimVar> stringAliasVars;
      list<SimCodeVar.SimVar> extObjVars;
      list<SimCodeVar.SimVar> constVars;
      list<SimCodeVar.SimVar> intConstVars;
      list<SimCodeVar.SimVar> boolConstVars;
      list<SimCodeVar.SimVar> stringConstVars;
      list<SimCodeVar.SimVar> jacobianVars;
      list<SimCodeVar.SimVar> realOptimizeConstraintsVars;
      list<SimCodeVar.SimVar> realOptimizeFinalConstraintsVars;

    case (SimCodeVar.SIMVARS(stateVars, derivativeVars, algVars, discreteAlgVars, intAlgVars, boolAlgVars, inputVars,
      outputVars, aliasVars, intAliasVars, boolAliasVars, paramVars, intParamVars, boolParamVars,
      stringAlgVars, stringParamVars, stringAliasVars, extObjVars, constVars, intConstVars, boolConstVars, stringConstVars,jacobianVars,realOptimizeConstraintsVars, realOptimizeFinalConstraintsVars))
      equation
        stateVars = rewriteIndex(stateVars, 0);
        derivativeVars = rewriteIndex(derivativeVars, 0);
        algVars = rewriteIndex(algVars, 0);
        discreteAlgVars = rewriteIndex(discreteAlgVars, 0);
        intAlgVars = rewriteIndex(intAlgVars, 0);
        boolAlgVars = rewriteIndex(boolAlgVars, 0);
        paramVars = rewriteIndex(paramVars, 0);
        intParamVars = rewriteIndex(intParamVars, 0);
        boolParamVars = rewriteIndex(boolParamVars, 0);
        aliasVars = rewriteIndex(aliasVars, 0);
        intAliasVars = rewriteIndex(intAliasVars, 0);
        boolAliasVars = rewriteIndex(boolAliasVars, 0);
        stringAlgVars = rewriteIndex(stringAlgVars, 0);
        stringParamVars = rewriteIndex(stringParamVars, 0);
        stringAliasVars = rewriteIndex(stringAliasVars, 0);
        constVars = rewriteIndex(constVars, 0);
        intConstVars = rewriteIndex(intConstVars, 0);
        boolConstVars = rewriteIndex(boolConstVars, 0);
        stringConstVars = rewriteIndex(stringConstVars, 0);
        extObjVars = rewriteIndex(extObjVars, 0);
        inputVars = rewriteIndex(inputVars, 0);
        outputVars = rewriteIndex(outputVars, 0);
        realOptimizeConstraintsVars = rewriteIndex(realOptimizeConstraintsVars, 0);
        realOptimizeFinalConstraintsVars = rewriteIndex(realOptimizeFinalConstraintsVars, 0);

        //jacobianVars don't need a index rewrite
      then SimCodeVar.SIMVARS(stateVars, derivativeVars, algVars, discreteAlgVars, intAlgVars, boolAlgVars, inputVars,
        outputVars, aliasVars, intAliasVars, boolAliasVars, paramVars, intParamVars, boolParamVars,
        stringAlgVars, stringParamVars, stringAliasVars, extObjVars, constVars, intConstVars, boolConstVars, stringConstVars, jacobianVars, realOptimizeConstraintsVars, realOptimizeFinalConstraintsVars);
  end match;
end fixIndex;

protected function rewriteIndex
  input list<SimCodeVar.SimVar> inVars;
  input Integer iindex;
  output list<SimCodeVar.SimVar> outVars;
algorithm
  outVars := rewriteIndexWork(inVars, iindex, {});
end rewriteIndex;

protected function rewriteIndexWork
  input list<SimCodeVar.SimVar> inVars;
  input Integer iindex;
  input list<SimCodeVar.SimVar> inAcc;
  output list<SimCodeVar.SimVar> outVars;
algorithm
  outVars :=
  match(inVars, iindex, inAcc)
    local
      DAE.ComponentRef name;
      BackendDAE.VarKind kind;
      String comment, unit, displayUnit;
      Option<DAE.Exp> minVal, maxVal;
      Option<DAE.Exp> initVal, nomVal;
      Boolean isFixed,isProtected;
      DAE.Type type_;
      Boolean isDiscrete, isValueChangeable;
      Option<DAE.ComponentRef> arrayCref;
      Integer index_;
      SimCodeVar.AliasVariable aliasvar;
      list<SimCodeVar.SimVar> rest, rest2;
      DAE.ElementSource source;
      SimCodeVar.Causality causality;
      list<String> numArrayElement;
      Integer index;
      SimCodeVar.SimVar var;

    case ({}, _, _) then listReverse(inAcc);
    case (SimCodeVar.SIMVAR(name, kind, comment, unit, displayUnit, _, minVal, maxVal, initVal, nomVal, isFixed, type_, isDiscrete, arrayCref, aliasvar, source, causality, NONE(), numArrayElement, isValueChangeable, isProtected)::rest, index_, _)
      then rewriteIndexWork(rest, index_ + 1, SimCodeVar.SIMVAR(name, kind, comment, unit, displayUnit, index_, minVal, maxVal, initVal, nomVal, isFixed, type_, isDiscrete, arrayCref, aliasvar, source, causality, NONE(), numArrayElement, isValueChangeable, isProtected)::inAcc);
  end match;
end rewriteIndexWork;

protected function setVariableIndex
  input SimCodeVar.SimVars inSimVars;
  output SimCodeVar.SimVars outSimVars;
algorithm
  outSimVars := match (inSimVars)
    local
      list<SimCodeVar.SimVar> stateVars;
      list<SimCodeVar.SimVar> derivativeVars;
      list<SimCodeVar.SimVar> algVars;
      list<SimCodeVar.SimVar> discreteAlgVars;
      list<SimCodeVar.SimVar> intAlgVars;
      list<SimCodeVar.SimVar> boolAlgVars;
      list<SimCodeVar.SimVar> inputVars;
      list<SimCodeVar.SimVar> outputVars;
      list<SimCodeVar.SimVar> aliasVars;
      list<SimCodeVar.SimVar> intAliasVars;
      list<SimCodeVar.SimVar> boolAliasVars;
      list<SimCodeVar.SimVar> paramVars;
      list<SimCodeVar.SimVar> intParamVars;
      list<SimCodeVar.SimVar> boolParamVars;
      list<SimCodeVar.SimVar> stringAlgVars;
      list<SimCodeVar.SimVar> stringParamVars;
      list<SimCodeVar.SimVar> stringAliasVars;
      list<SimCodeVar.SimVar> extObjVars;
      list<SimCodeVar.SimVar> constVars;
      list<SimCodeVar.SimVar> intConstVars;
      list<SimCodeVar.SimVar> boolConstVars;
      list<SimCodeVar.SimVar> stringConstVars;
      list<SimCodeVar.SimVar> jacobianVars;
      list<SimCodeVar.SimVar> realOptimizeConstraintsVars;
      list<SimCodeVar.SimVar> realOptimizeFinalConstraintsVars;
      Integer index_;

    case (SimCodeVar.SIMVARS(stateVars, derivativeVars, algVars, discreteAlgVars, intAlgVars, boolAlgVars, inputVars,
      outputVars, aliasVars, intAliasVars, boolAliasVars, paramVars, intParamVars, boolParamVars,
      stringAlgVars, stringParamVars, stringAliasVars, extObjVars, constVars, intConstVars, boolConstVars, stringConstVars,jacobianVars,realOptimizeConstraintsVars, realOptimizeFinalConstraintsVars))
      equation
        (stateVars, index_) = setVariableIndexHelper(stateVars, 1);
        (derivativeVars, index_) = setVariableIndexHelper(derivativeVars, index_);
        (algVars, index_) = setVariableIndexHelper(algVars, index_);
        (discreteAlgVars, index_) = setVariableIndexHelper(discreteAlgVars, index_);
        (intAlgVars, index_) = setVariableIndexHelper(intAlgVars, index_);
        (boolAlgVars, index_) = setVariableIndexHelper(boolAlgVars, index_);
        (paramVars, index_) = setVariableIndexHelper(paramVars, index_);
        (intParamVars, index_) = setVariableIndexHelper(intParamVars, index_);
        (boolParamVars, index_) = setVariableIndexHelper(boolParamVars, index_);
        (aliasVars, index_) = setVariableIndexHelper(aliasVars, index_);
        (intAliasVars, index_) = setVariableIndexHelper(intAliasVars, index_);
        (boolAliasVars, index_) = setVariableIndexHelper(boolAliasVars, index_);
        (stringAlgVars, index_) = setVariableIndexHelper(stringAlgVars, index_);
        (stringParamVars, index_) = setVariableIndexHelper(stringParamVars, index_);
        (stringAliasVars, index_) = setVariableIndexHelper(stringAliasVars, index_);
        (constVars, index_) = setVariableIndexHelper(constVars, index_);
        (intConstVars, index_) = setVariableIndexHelper(intConstVars, index_);
        (boolConstVars, index_) = setVariableIndexHelper(boolConstVars, index_);
        (stringConstVars, index_) = setVariableIndexHelper(stringConstVars, index_);
        (extObjVars, index_) = setVariableIndexHelper(extObjVars, index_);
        (inputVars, index_) = setVariableIndexHelper(inputVars, index_);
        (outputVars, index_) = setVariableIndexHelper(outputVars, index_);
        (realOptimizeConstraintsVars, index_) = setVariableIndexHelper(realOptimizeConstraintsVars, index_);
        (realOptimizeFinalConstraintsVars, index_) = setVariableIndexHelper(realOptimizeFinalConstraintsVars, index_);
        //jacobianVars don't need a index rewrite
      then SimCodeVar.SIMVARS(stateVars, derivativeVars, algVars, discreteAlgVars, intAlgVars, boolAlgVars, inputVars,
        outputVars, aliasVars, intAliasVars, boolAliasVars, paramVars, intParamVars, boolParamVars,
        stringAlgVars, stringParamVars, stringAliasVars, extObjVars, constVars, intConstVars, boolConstVars, stringConstVars, jacobianVars, realOptimizeConstraintsVars, realOptimizeFinalConstraintsVars);
  end match;
end setVariableIndex;

protected function setVariableIndexHelper
  input list<SimCodeVar.SimVar> inVars;
  input Integer inIndex;
  output list<SimCodeVar.SimVar> outVars;
  output Integer outIndex;
algorithm
  (outVars, outIndex) := List.mapFold(inVars, setVariableIndexHelper2, inIndex);
end setVariableIndexHelper;

protected function setVariableIndexHelper2
  input SimCodeVar.SimVar inVar;
  input Integer inIndex;
  output SimCodeVar.SimVar outVar;
  output Integer outIndex;
algorithm
  (outVar, outIndex) := match(inVar, inIndex)
    local
      DAE.ComponentRef name;
      BackendDAE.VarKind kind;
      String comment, unit, displayUnit;
      Integer index;
      Option<DAE.Exp> minVal, maxVal;
      Option<DAE.Exp> initVal, nomVal;
      Boolean isFixed,isProtected;
      DAE.Type type_;
      Boolean isDiscrete, isValueChangeable;
      Option<DAE.ComponentRef> arrayCref;
      SimCodeVar.AliasVariable aliasvar;
      DAE.ElementSource source;
      SimCodeVar.Causality causality;
      list<String> numArrayElement;
      Integer index_, next_index;

    case (SimCodeVar.SIMVAR(name, kind, comment, unit, displayUnit, index, minVal,
          maxVal, initVal, nomVal, isFixed, type_, isDiscrete, arrayCref, aliasvar,
          source, causality, _, numArrayElement, isValueChangeable, isProtected),
          index_)
      equation
        next_index = index_ + 1;
      then
        (SimCodeVar.SIMVAR(name, kind, comment, unit, displayUnit, index,
         minVal, maxVal, initVal, nomVal, isFixed, type_, isDiscrete, arrayCref,
         aliasvar, source, causality, SOME(index_), numArrayElement,
         isValueChangeable, isProtected), next_index);

    else (inVar, inIndex);
  end match;
end setVariableIndexHelper2;

public function createCrefToSimVarHT
  input SimCode.ModelInfo modelInfo;
  output SimCode.HashTableCrefToSimVar outHT;
algorithm
  outHT :=  matchcontinue (modelInfo)
    local
      SimCode.HashTableCrefToSimVar ht;
      list<SimCodeVar.SimVar> stateVars, derivativeVars, algVars, discreteAlgVars, intAlgVars, boolAlgVars, aliasVars,
                            intAliasVars, boolAliasVars, stringAliasVars, paramVars, intParamVars, boolParamVars,
                            stringAlgVars, stringParamVars, extObjVars, constVars, intConstVars, boolConstVars,
                            stringConstVars, jacobianVars, realOptimizeConstraintsVars, realOptimizeFinalConstraintsVars;
      Integer numStateVars,numAlgVars,numIntAlgVars,numBoolAlgVars,numAlgAliasVars,numIntAliasVars;
      Integer numBoolAliasVars,numParams,numIntParams,numBoolParams,numOutVars,numInVars,numOptimizeConstraints, numOptimizeFinalConstraints, size;
    case (SimCode.MODELINFO(varInfo = SimCode.VARINFO(numStateVars=numStateVars,numAlgVars=numAlgVars,
      numIntAlgVars=numIntAlgVars,numBoolAlgVars=numBoolAlgVars,numAlgAliasVars=numAlgAliasVars,numIntAliasVars=numIntAliasVars,
      numBoolAliasVars=numBoolAliasVars,numParams=numParams,numIntParams=numIntParams,numBoolParams=numBoolParams,
      numOutVars=numOutVars,numInVars=numInVars, numOptimizeConstraints= numOptimizeConstraints, numOptimizeFinalConstraints = numOptimizeFinalConstraints),
      vars = SimCodeVar.SIMVARS(
      stateVars, derivativeVars, algVars, discreteAlgVars, intAlgVars, boolAlgVars,
      _/*inputVars*/, _/*outputVars*/, aliasVars, intAliasVars, boolAliasVars, paramVars, intParamVars, boolParamVars,
      stringAlgVars, stringParamVars, stringAliasVars, extObjVars, constVars, intConstVars, boolConstVars, stringConstVars, jacobianVars, realOptimizeConstraintsVars, realOptimizeFinalConstraintsVars)))
      equation
        size = numStateVars+numAlgVars+numIntAlgVars+numBoolAlgVars+numAlgAliasVars+numIntAliasVars+
               numBoolAliasVars+numParams+numIntParams+numBoolParams+numOutVars+numInVars + numOptimizeConstraints + numOptimizeFinalConstraints;
        size = intMax(size,1000);
        ht = emptyHashTableSized(size);
        ht = List.fold(stateVars, addSimVarToHashTable, ht);
        ht = List.fold(derivativeVars, addSimVarToHashTable, ht);
        ht = List.fold(algVars, addSimVarToHashTable, ht);
        ht = List.fold(discreteAlgVars, addSimVarToHashTable, ht);
        ht = List.fold(intAlgVars, addSimVarToHashTable, ht);
        ht = List.fold(boolAlgVars, addSimVarToHashTable, ht);
        ht = List.fold(paramVars, addSimVarToHashTable, ht);
        ht = List.fold(intParamVars, addSimVarToHashTable, ht);
        ht = List.fold(boolParamVars, addSimVarToHashTable, ht);
        ht = List.fold(aliasVars, addSimVarToHashTable, ht);
        ht = List.fold(intAliasVars, addSimVarToHashTable, ht);
        ht = List.fold(boolAliasVars, addSimVarToHashTable, ht);
        ht = List.fold(stringAlgVars, addSimVarToHashTable, ht);
        ht = List.fold(stringParamVars, addSimVarToHashTable, ht);
        ht = List.fold(stringAliasVars, addSimVarToHashTable, ht);
        ht = List.fold(extObjVars, addSimVarToHashTable, ht);
        ht = List.fold(constVars, addSimVarToHashTable, ht);
        ht = List.fold(intConstVars, addSimVarToHashTable, ht);
        ht = List.fold(boolConstVars, addSimVarToHashTable, ht);
        ht = List.fold(stringConstVars, addSimVarToHashTable, ht);
        ht = List.fold(jacobianVars, addSimVarToHashTable, ht);
        ht = List.fold(realOptimizeConstraintsVars, addSimVarToHashTable, ht);
        ht = List.fold(realOptimizeFinalConstraintsVars, addSimVarToHashTable, ht);
      then
        ht;
    case (_)
      equation
        Error.addMessage(Error.INTERNAL_ERROR, {"createCrefToSimVarHT failed"});
      then
        fail();
  end matchcontinue;
end createCrefToSimVarHT;

public function addSimVarToHashTable
  input SimCodeVar.SimVar simvarIn;
  input  SimCode.HashTableCrefToSimVar inHT;
  output SimCode.HashTableCrefToSimVar outHT;
algorithm
  outHT :=
  matchcontinue (simvarIn, inHT)
    local
      DAE.ComponentRef cr, acr;
      SimCodeVar.SimVar sv;

    case (sv as SimCodeVar.SIMVAR(name = cr, arrayCref = NONE()), _)
      equation
        outHT = add((cr, sv), inHT);
      then outHT;
        // add the whole array crefs to the hashtable, too
    case (sv as SimCodeVar.SIMVAR(name = cr, arrayCref = SOME(acr)), _)
      equation
        outHT = add((acr, sv), inHT);
        outHT = add((cr, sv), outHT);
      then outHT;
    case (_, _)
      equation
        Error.addMessage(Error.INTERNAL_ERROR, {"addSimVarToHashTable failed"});
      then
        fail();
  end matchcontinue;
end addSimVarToHashTable;


protected function getAliasVar
  input BackendDAE.Var inVar;
  input Option<BackendDAE.Variables> inAliasVars;
  output SimCodeVar.AliasVariable outAlias;
algorithm
  outAlias :=
  matchcontinue (inVar, inAliasVars)
    local
      DAE.ComponentRef name;
      BackendDAE.Variables aliasVars;
      BackendDAE.Var var;
      DAE.Exp e;
      SimCodeVar.AliasVariable alias;
    case (BackendDAE.VAR(varName=name), SOME(aliasVars))
      equation
        ((var :: _), _) = BackendVariable.getVar(name, aliasVars);
        // does not work
        // e = BaseHashTable.get(name, varMappings);
        e = BackendVariable.varBindExp(var);
        (e, _) = ExpressionSimplify.simplify(e);
        alias = getAliasVar1(e, var);
      then alias;
    case(_, _) then SimCodeVar.NOALIAS();
  end matchcontinue;
end getAliasVar;

protected function getAliasVar1
  input DAE.Exp inExp;
  input BackendDAE.Var inVar;
  output SimCodeVar.AliasVariable outAlias;
algorithm
  outAlias :=
  matchcontinue (inExp, inVar)
    local
      DAE.ComponentRef name;
      Absyn.Path fname;

    case (DAE.CREF(componentRef=name), _) then SimCodeVar.ALIAS(name);
    case (DAE.UNARY(operator=DAE.UMINUS(_), exp=DAE.CREF(componentRef=name)), _) then SimCodeVar.NEGATEDALIAS(name);
    case (DAE.UNARY(operator=DAE.UMINUS_ARR(_), exp=DAE.CREF(componentRef=name)), _) then SimCodeVar.NEGATEDALIAS(name);
    case (DAE.LUNARY(operator=DAE.NOT(_), exp=DAE.CREF(componentRef=name)), _) then SimCodeVar.NEGATEDALIAS(name);
    case (DAE.CALL(path=fname, expLst={DAE.CREF(componentRef=name)}), _)
      equation
      Builtin.isDer(fname);
       name = ComponentReference.crefPrefixDer(name);
    then SimCodeVar.ALIAS(name);
    case (DAE.UNARY(operator=DAE.UMINUS(_), exp=DAE.CALL(path=fname, expLst={DAE.CREF(componentRef=name)})), _)
      equation
       Builtin.isDer(fname);
       name = ComponentReference.crefPrefixDer(name);
    then SimCodeVar.NEGATEDALIAS(name);
    case (DAE.UNARY(operator=DAE.UMINUS_ARR(_), exp=DAE.CALL(path=fname, expLst={DAE.CREF(componentRef=name)})), _)
      equation
       Builtin.isDer(fname);
       name = ComponentReference.crefPrefixDer(name);
    then SimCodeVar.NEGATEDALIAS(name);
    case(_, _) then SimCodeVar.NOALIAS();
  end matchcontinue;
end getAliasVar1;

protected function unparseCommentOptionNoAnnotationNoQuote
  input Option<SCode.Comment> absynComment;
  output String commentStr;
algorithm
  commentStr := matchcontinue (absynComment)
    case (SOME(SCode.COMMENT(_, SOME(commentStr)))) then commentStr;
    case (_) then "";
  end matchcontinue;
end unparseCommentOptionNoAnnotationNoQuote;

// =============================================================================
// section for ???
//
// =============================================================================

protected function solveTrivialArrayEquation "Solves some trivial array equations, like v+v2=foo(...), w.r.t. v is v=foo(...)-v2"
  input DAE.ComponentRef v;
  input DAE.Exp e1;
  input DAE.Exp e2;
  output DAE.Exp outE1;
  output DAE.Exp outE2;
algorithm
  (outE1, outE2) := matchcontinue(v, e1, e2)
    local
      DAE.Exp e, e12, e22, vTerm, res, rhs, f;
      list<DAE.Exp> exps, exps_1;
      DAE.Type tp;
      Boolean b;
      DAE.ComponentRef c;

    case (_, DAE.ARRAY( tp, _, exps as ((DAE.UNARY(DAE.UMINUS(_), DAE.CREF(componentRef=c)) :: _))), _)
      equation
        (f::exps_1) = List.map(exps, Expression.expStripLastSubs); // Strip last subscripts
        List.map1AllValue(exps_1, Expression.expEqual, true, f);
        c = ComponentReference.crefStripLastSubs(c);
        (e12, e22) = solveTrivialArrayEquation(v, Expression.makeCrefExp(c, tp), Expression.negate(e2));
      then
        (e12, e22);

    case (_, _, DAE.ARRAY( tp, _, exps as ((DAE.UNARY(DAE.UMINUS(_), DAE.CREF(componentRef=c)) :: _))))
      equation
        (f::exps_1) = List.map(exps, Expression.expStripLastSubs); // Strip last subscripts
        List.map1AllValue(exps_1, Expression.expEqual, true, f);
        c = ComponentReference.crefStripLastSubs(c);
        (e12, e22) = solveTrivialArrayEquation(v, Expression.negate(e2), Expression.makeCrefExp(c, tp));
      then
        (e12, e22);

        // Solve simple linear equations.
    case(_, _, _)
      equation
        e = Expression.expSub(e1, e2);
        (res, _) = ExpressionSimplify.simplify(e);
        (f, rhs) = Expression.getTermsContainingX(res, Expression.crefExp(v));
        (vTerm, _) = ExpressionSimplify.simplify(f);
        (e22, rhs) = solveTrivialArrayEquation2(vTerm, rhs);
      then
        (e22, rhs);

        // not succeded to solve, return unsolved equation., catched later.
    case (_, _, _) then (e1, e2);
  end matchcontinue;
end solveTrivialArrayEquation;

protected function solveTrivialArrayEquation2
"author: Frenkel TUD - 2012-07
  helper for solveTrivialArrayEquation"
  input DAE.Exp e1;
  input DAE.Exp e2;
  output DAE.Exp outE1;
  output DAE.Exp outE2;
algorithm
  (outE1, outE2) := match(e1, e2)
    local
      DAE.Exp lhs, rhs;
    case(DAE.CREF(), _)
      equation
        (rhs, _) = ExpressionSimplify.simplify(Expression.negate(e2));
      then
        (e1, rhs);

    case(DAE.UNARY(exp=lhs as DAE.CREF()), _)
      equation
        (rhs, _) = ExpressionSimplify.simplify(e2);
      then
        (lhs, rhs);

  end match;
end solveTrivialArrayEquation2;

protected function getVectorizedCrefFromExp "author: PA
  Returns the component ref v if expression is on form
   {v{1}, v{2}, ...v{n}}  for some n.
  TODO: implement for 2D as well."
  input DAE.Exp inExp;
  output DAE.ComponentRef outComponentRef;
algorithm
  outComponentRef := match (inExp)
    local
      list<DAE.ComponentRef> crefs, crefs_1;
      DAE.ComponentRef cr;
      list<DAE.Exp> expl;
      list<list<DAE.Exp>> column;

    case (DAE.ARRAY(array = expl))
      equation
        ((crefs as (cr :: _))) = List.map(expl, Expression.expCref); // Get all CRefs from exp1.
        crefs_1 = List.map(crefs, ComponentReference.crefStripLastSubs); // Strip last subscripts
        List.reduce(crefs_1, ComponentReference.crefEqualReturn); // Check if elements are equal, remove one
      then
        cr;

    case (DAE.MATRIX(matrix = column))
      equation
        expl = List.flatten(column);
        ((crefs as (cr :: _))) = List.map(expl, Expression.expCref); // Get all CRefs from exp1.
        crefs_1 = List.map(crefs, ComponentReference.crefStripLastSubs); // Strip last subscripts
        List.reduce(crefs_1, ComponentReference.crefEqualReturn); // Check if elements are equal, remove one
      then
        cr;
  end match;
end getVectorizedCrefFromExp;

protected function getCalledFunctionsInFunctions "Goes through the given DAE, finds the given functions and collects
  the names of the functions called from within those functions"
  input list<Absyn.Path> paths;
  input HashTableStringToPath.HashTable inHt;
  input DAE.FunctionTree funcs;
  output HashTableStringToPath.HashTable outHt;
algorithm
  outHt := match (paths, inHt, funcs)
    local
      list<Absyn.Path> rest;
      Absyn.Path path;
      HashTableStringToPath.HashTable ht;

    case ({}, ht, _) then ht;
    case (path::rest, ht, _)
      equation
        ht = getCalledFunctionsInFunction2(path, Absyn.pathStringNoQual(path), ht, funcs);
        ht = getCalledFunctionsInFunctions(rest, ht, funcs);
      then ht;
  end match;
end getCalledFunctionsInFunctions;

public function getCalledFunctionsInFunction2 "Goes through the given DAE, finds the given function and collects
  the names of the functions called from within those functions"
  input Absyn.Path inPath;
  input String pathstr;
  input HashTableStringToPath.HashTable inHt "paths to not add";
  input DAE.FunctionTree funcs;
  output HashTableStringToPath.HashTable outHt "paths to not add";
algorithm
  outHt := matchcontinue (inPath, pathstr, inHt, funcs)
    local
      String str;
      Absyn.Path path;
      DAE.Function funcelem;
      list<Absyn.Path> calledfuncs, varfuncs;
      list<DAE.Element> els;
      HashTableStringToPath.HashTable ht;

    case (_, _, ht, _)
      equation
        BaseHashTable.get(pathstr, ht);
      then ht;

    case (path, _, ht, _)
      equation
        funcelem = DAEUtil.getNamedFunction(path, funcs);
        els = DAEUtil.getFunctionElements(funcelem);
        // SimCode.Function reference variables are filtered out
        varfuncs = List.fold(els, DAEUtil.collectFunctionRefVarPaths, {});
        (_, (_, varfuncs)) = DAEUtil.traverseDAE2(els, Expression.traverseSubexpressionsHelper, (DAEUtil.collectValueblockFunctionRefVars, varfuncs));
        (_, (_, (calledfuncs, _))) = DAEUtil.traverseDAE2(els, Expression.traverseSubexpressionsHelper, (matchNonBuiltinCallsAndFnRefPaths, ({}, varfuncs)));
        ht = BaseHashTable.add((pathstr, path), ht);
        ht = addDestructor(funcelem, ht);
        ht = getCalledFunctionsInFunctions(calledfuncs, ht, funcs);
      then ht;

    case (path, _, _, _)
      equation
        failure(_ = DAEUtil.getNamedFunction(path, funcs));
        str = "function getCalledFunctionsInFunction2: Class " + pathstr + " not found in global scope.";
        Error.addMessage(Error.INTERNAL_ERROR, {str});
      then
        fail();
  end matchcontinue;
end getCalledFunctionsInFunction2;

protected function addDestructor
  input DAE.Function func;
  input HashTableStringToPath.HashTable inHt;
  output HashTableStringToPath.HashTable outHt;
algorithm
  outHt := match (func,inHt)
    local
      Absyn.Path path;
      String pathstr;
    case (DAE.FUNCTION(type_=DAE.T_FUNCTION(funcResultType=DAE.T_COMPLEX(complexClassType=ClassInf.EXTERNAL_OBJ(path=path)))),_)
      equation
        path = Absyn.joinPaths(path,Absyn.IDENT("destructor"));
      then addDestructor2(path,Absyn.pathStringNoQual(path),inHt);
    else inHt;
  end match;
end addDestructor;

protected function addDestructor2
  input Absyn.Path path;
  input String pathstr;
  input HashTableStringToPath.HashTable inHt;
  output HashTableStringToPath.HashTable ht := inHt;
algorithm
  if not BaseHashTable.hasKey(pathstr, ht) then
    BaseHashTable.add((pathstr, path), ht);
  end if;
end addDestructor2;

// =============================================================================
// section for ???
//
// =============================================================================

protected function isVarQ
"Succeeds if inElement is a variable or constant that is not input."
  input DAE.Element inElement;
algorithm
  _ := match (inElement)
    local
      DAE.VarKind vk;
      DAE.VarDirection vd;
    case DAE.VAR(kind=vk, direction=vd)
      equation
        isVarVarOrConstant(vk);
        isDirectionNotInput(vd);
      then ();
  end match;
end isVarQ;

/*mahge: kernel functions*/
protected function isVarNotInputNotOutput
"Succeeds if inElement is a variable or constant that is not input or output.
needed in kernel functions since they shouldn't have output vars."
  input DAE.Element inElement;
algorithm
  _ := match (inElement)
    local
      DAE.VarKind vk;
      DAE.VarDirection vd;
    case DAE.VAR(kind=vk, direction=vd)
      equation
        isVarVarOrConstant(vk);
        isDirectionNotInputNotOutput(vd);
      then ();
  end match;
end isVarNotInputNotOutput;

protected function isVarVarOrConstant
  input DAE.VarKind inVarKind;
algorithm
  _ := match (inVarKind)
    case DAE.VARIABLE() then ();
    case DAE.PARAM() then ();
    case DAE.CONST() then ();
  end match;
end isVarVarOrConstant;

protected function isDirectionNotInput
  input DAE.VarDirection inVarDirection;
algorithm
  _ := match (inVarDirection)
    case DAE.OUTPUT() then ();
    case DAE.BIDIR() then ();
  end match;
end isDirectionNotInput;

protected function isDirectionNotInputNotOutput
  input DAE.VarDirection inVarDirection;
algorithm
  _ := match (inVarDirection)
    case DAE.BIDIR() then ();
  end match;
end isDirectionNotInputNotOutput;

protected function filterNg "Sets the number of zero crossings to zero if events are disabled."
  input Integer ng;
  output Integer outInteger;
algorithm
  outInteger := if useZerocrossing() then ng else 0;
end filterNg;

protected function useZerocrossing
  output Boolean res;
algorithm
  res := Flags.isSet(Flags.EVENTS);
end useZerocrossing;

protected function getCrefFromExp "Assume input Exp is CREF and return the ComponentRef, fail otherwise."
  input DAE.Exp e;
  output Absyn.ComponentRef c;
algorithm
  c := match (e)
    local
      DAE.ComponentRef crefe;
      Absyn.ComponentRef crefa;

    case(DAE.CREF(componentRef = crefe))
      equation
        crefa = ComponentReference.unelabCref(crefe);
      then
        crefa;

    else
      equation
        Error.addInternalError("function getCrefFromExp failed: input was not of type DAE.CREF", sourceInfo());
      then
        fail();
  end match;
end getCrefFromExp;

protected function scodeParallelismToDAEParallelism
  input SCode.Parallelism inParallelism;
  output DAE.VarParallelism outParallelism;
algorithm
  outParallelism := match(inParallelism)
    case(SCode.PARGLOBAL())    then DAE.PARGLOBAL();
    case(SCode.PARLOCAL())     then DAE.PARLOCAL();
    case(SCode.NON_PARALLEL()) then DAE.NON_PARALLEL();
  end match;
end scodeParallelismToDAEParallelism;

protected function typesVarNoBinding
  input DAE.Var inTypesVar;
  output SimCode.Variable outVar;
algorithm
  outVar := match (inTypesVar)
    local
      String name;
      DAE.Type ty;
      DAE.ComponentRef cref_;
      DAE.Attributes attr;
      SCode.Parallelism scPrl;
      DAE.VarParallelism prl;

    case (DAE.TYPES_VAR(name=name, attributes = attr, ty=ty))
      equation
        ty = Types.simplifyType(ty);
        cref_ = ComponentReference.makeCrefIdent(name, ty, {});
        DAE.ATTR(parallelism = scPrl) = attr;
        prl = scodeParallelismToDAEParallelism(scPrl);
      then SimCode.VARIABLE(cref_, ty, NONE(), {}, prl,DAE.VARIABLE());
  end match;
end typesVarNoBinding;

protected function typesVar
  input DAE.Var inTypesVar;
  output SimCode.Variable outVar;
algorithm
  outVar := match (inTypesVar)
    local
      String name;
      DAE.Type ty;
      DAE.ComponentRef cref_;
      DAE.Attributes attr;
      SCode.Parallelism scPrl;
      DAE.VarParallelism prl;
      DAE.Exp bindExp;

    case (DAE.TYPES_VAR(name=name, attributes = attr, ty=ty))
      equation
        ty = Types.simplifyType(ty);
        cref_ = ComponentReference.makeCrefIdent(name, ty, {});
        DAE.ATTR(parallelism = scPrl) = attr;
        prl = scodeParallelismToDAEParallelism(scPrl);
        bindExp = Types.getBindingExp(inTypesVar, Absyn.IDENT(name));
      then SimCode.VARIABLE(cref_, ty, SOME(bindExp), {}, prl, DAE.VARIABLE());
  end match;
end typesVar;

protected function dlowvarToSimvar
  input BackendDAE.Var dlowVar;
  input Option<BackendDAE.Variables> optAliasVars;
  input BackendDAE.Variables inVars;
  output SimCodeVar.SimVar simVar;
algorithm
  simVar := match (dlowVar, optAliasVars, inVars)
    local
      DAE.ComponentRef cr;
      BackendDAE.VarKind kind;
      DAE.VarDirection dir;
      list<DAE.Dimension> inst_dims;
      list<String> numArrayElement;
      Option<DAE.VariableAttributes> dae_var_attr;
      Option<SCode.Comment> comment;
      BackendDAE.Type tp;
      String  commentStr, unit, displayUnit;
      Option<DAE.Exp> minValue, maxValue;
      Option<DAE.Exp> initVal;
      Option<DAE.Exp> nomVal;
      Boolean isFixed;
      DAE.Type type_;
      Boolean isDiscrete, isValueChangeable;
      Option<DAE.ComponentRef> arrayCref;
      SimCodeVar.AliasVariable aliasvar;
      DAE.ElementSource source;
      BackendDAE.Variables vars;
      SimCodeVar.Causality caus;
      Boolean isProtected;

    case ((BackendDAE.VAR(varName = cr,
      varKind = kind as BackendDAE.PARAM(),
      arryDim = inst_dims,
      values = dae_var_attr,
      comment = comment,
      varType = tp,
      source = source)), _, vars)
      equation
        commentStr = unparseCommentOptionNoAnnotationNoQuote(comment);
        (unit, displayUnit) = extractVarUnit(dae_var_attr);
        isProtected = getProtected(dae_var_attr);
        (minValue, maxValue) = getMinMaxValues(dlowVar);
        initVal = getStartValue(dlowVar);
        nomVal = getNominalValue(dlowVar);
        // checkInitVal(initVal, source);
        isFixed = BackendVariable.varFixed(dlowVar);
        type_ = tp;
        isDiscrete = BackendVariable.isVarDiscrete(dlowVar);
        arrayCref = ComponentReference.getArrayCref(cr);
        aliasvar = getAliasVar(dlowVar, optAliasVars);
        caus = getCausality(dlowVar, vars);
        numArrayElement = List.map(inst_dims, ExpressionDump.dimensionIntString);
        // print("name: " + ComponentReference.printComponentRefStr(cr) + "indx: " + intString(indx) + "\n");
        // check if the variable has changeable value
        // parameter which has final = true or evaluate annotation are not changeable
        isValueChangeable = ((not BackendVariable.hasVarEvaluateAnnotationOrFinal(dlowVar)
                            and BackendVariable.varHasConstantBindExp(dlowVar))
                            or not BackendVariable.varHasBindExp(dlowVar))
                            and isFixed;
      then
        SimCodeVar.SIMVAR(cr, kind, commentStr, unit, displayUnit, -1 /* use -1 to get an error in simulation if something failed */,
        minValue, maxValue, initVal, nomVal, isFixed, type_, isDiscrete, arrayCref, aliasvar, source, caus, NONE(), numArrayElement, isValueChangeable, isProtected);

    // Start value of states may be changeable
    case ((BackendDAE.VAR(varName = cr,
      varKind = kind as BackendDAE.STATE(),
      arryDim = inst_dims,
      values = dae_var_attr,
      comment = comment,
      varType = tp,
      source = source)), _, vars)
      equation
        commentStr = unparseCommentOptionNoAnnotationNoQuote(comment);
        (unit, displayUnit) = extractVarUnit(dae_var_attr);
        isProtected = getProtected(dae_var_attr);
        (minValue, maxValue) = getMinMaxValues(dlowVar);
        initVal = getStartValue(dlowVar);
        nomVal = getNominalValue(dlowVar);
        // checkInitVal(initVal, source);
        isFixed = BackendVariable.varFixed(dlowVar);
        type_ = tp;
        isDiscrete = BackendVariable.isVarDiscrete(dlowVar);
        arrayCref = ComponentReference.getArrayCref(cr);
        aliasvar = getAliasVar(dlowVar, optAliasVars);
        caus = getCausality(dlowVar, vars);
        numArrayElement = List.map(inst_dims, ExpressionDump.dimensionIntString);
        // print("name: " + ComponentReference.printComponentRefStr(cr) + "indx: " + intString(indx) + "\n");
      then
        SimCodeVar.SIMVAR(cr, kind, commentStr, unit, displayUnit, -1 /* use -1 to get an error in simulation if something failed */,
        minValue, maxValue, initVal, nomVal, isFixed, type_, isDiscrete, arrayCref, aliasvar, source, caus, NONE(), numArrayElement, true, isProtected);

    case ((BackendDAE.VAR(varName = cr,
      varKind = kind,
      arryDim = inst_dims,
      values = dae_var_attr,
      comment = comment,
      varType = tp,
      source = source)), _, vars)
      equation
        commentStr = unparseCommentOptionNoAnnotationNoQuote(comment);
        (unit, displayUnit) = extractVarUnit(dae_var_attr);
        isProtected = getProtected(dae_var_attr);
        (minValue, maxValue) = getMinMaxValues(dlowVar);
        initVal = getStartValue(dlowVar);
        nomVal = getNominalValue(dlowVar);
        // checkInitVal(initVal, source);
        isFixed = BackendVariable.varFixed(dlowVar);
        type_ = tp;
        isDiscrete = BackendVariable.isVarDiscrete(dlowVar);
        arrayCref = ComponentReference.getArrayCref(cr);
        aliasvar = getAliasVar(dlowVar, optAliasVars);
        caus = getCausality(dlowVar, vars);
        numArrayElement = List.map(inst_dims, ExpressionDump.dimensionIntString);
        // print("name: " + ComponentReference.printComponentRefStr(cr) + "indx: " + intString(indx) + "\n");
      then
        SimCodeVar.SIMVAR(cr, kind, commentStr, unit, displayUnit, -1 /* use -1 to get an error in simulation if something failed */,
        minValue, maxValue, initVal, nomVal, isFixed, type_, isDiscrete, arrayCref, aliasvar, source, caus, NONE(), numArrayElement, false, isProtected);
  end match;
end dlowvarToSimvar;

// lochel: This will now be checked in CodegenUtil.tpl (see #2597/#2601)
// protected function checkInitVal
//   input Option<DAE.Exp> oexp;
//   input DAE.ElementSource source;
// algorithm
//   _ := match (oexp, source)
//     local
//       SourceInfo info;
//       String str;
//       DAE.Exp exp;
//     case (NONE(), _) then ();
//     case (SOME(DAE.RCONST(_)), _) then ();
//     case (SOME(DAE.ICONST(_)), _) then ();
//     case (SOME(DAE.SCONST(_)), _) then ();
//     case (SOME(DAE.BCONST(_)), _) then ();
//     // adrpo, 2011-04-18 -> enumeration literal is OK also
//     case (SOME(DAE.ENUM_LITERAL(index = _)), _) then ();
//     case (SOME(DAE.CALL(attr=DAE.CALL_ATTR(ty=DAE.T_COMPLEX(complexClassType=ClassInf.EXTERNAL_OBJ(path=_))))), _) then ();
//     case (SOME(exp), DAE.SOURCE(info=info))
//       equation
//         str = "Initial value of unknown type: " + ExpressionDump.printExpStr(exp);
//         Error.addSourceMessage(Error.INTERNAL_ERROR, {str}, info);
//       then ();
//   end match;
// end checkInitVal;

protected function getCausality
  input BackendDAE.Var dlowVar;
  input BackendDAE.Variables inVars;
  output SimCodeVar.Causality caus;
algorithm
  caus := matchcontinue (dlowVar, inVars)
    local
      DAE.ComponentRef cr;
      BackendDAE.Variables knvars;
    case (BackendDAE.VAR(varName = DAE.CREF_IDENT(), varDirection = DAE.OUTPUT()), _) then SimCodeVar.OUTPUT();
    case (BackendDAE.VAR(varName = cr, varDirection = DAE.INPUT()), knvars)
      equation
        (_, _) = BackendVariable.getVar(cr, knvars);
      then SimCodeVar.INPUT();
    case(_, _) then SimCodeVar.INTERNAL();
  end matchcontinue;
end getCausality;

protected function traversingdlowvarToSimvarFold
  input BackendDAE.Var v;
  input tuple<list<SimCodeVar.SimVar>, BackendDAE.Variables> inTpl;
  output tuple<list<SimCodeVar.SimVar>, BackendDAE.Variables> outTpl;
algorithm
  (_, outTpl) := traversingdlowvarToSimvar(v, inTpl);
end traversingdlowvarToSimvarFold;

protected function traversingdlowvarToSimvar
  input BackendDAE.Var inVar;
  input tuple<list<SimCodeVar.SimVar>, BackendDAE.Variables> inTpl;
  output BackendDAE.Var outVar;
  output tuple<list<SimCodeVar.SimVar>, BackendDAE.Variables> outTpl;
algorithm
  (outVar,outTpl) := match (inVar,inTpl)
    local
      BackendDAE.Var v;
      list<SimCodeVar.SimVar> sv_lst;
      SimCodeVar.SimVar sv;
      BackendDAE.Variables vars;
    case (v, (sv_lst, vars))
      equation
        sv = dlowvarToSimvar(v, NONE(), vars);
      then (v, (sv::sv_lst, vars));
    else (inVar,inTpl);
  end match;
end traversingdlowvarToSimvar;

protected function subsToScalar "scalar expression."
  input list<DAE.Subscript> inExpSubscriptLst;
  output Boolean outBoolean;
algorithm
  outBoolean := match (inExpSubscriptLst)
    local
      Boolean b;
      list<DAE.Subscript> r;
    case {} then true;
    case (DAE.SLICE() :: _) then false;
    case (DAE.WHOLEDIM() :: _) then false;
    case (DAE.INDEX() :: r)
      equation
        b = subsToScalar(r);
      then
        b;
  end match;
end subsToScalar;

public function getMatchingExpsList
  input list<DAE.Exp> inExps;
  input MatchFn inFn;
  output list<DAE.Exp> outExpLst;
  partial function MatchFn
    input DAE.Exp inExp;
    input list<DAE.Exp> inExps;
    output DAE.Exp outExp;
    output list<DAE.Exp> outExps;
  end MatchFn;
algorithm
  (_, outExpLst) := Expression.traverseExpList(inExps, inFn, {});
end getMatchingExpsList;

protected function matchNonBuiltinCallsAndFnRefPaths "The extra argument is a tuple<list, list>; the second list is the list of variable
  names to filter out (so we don't add function references variables)"
  input DAE.Exp inExp;
  input tuple<list<Absyn.Path>, list<Absyn.Path>> itpl;
  output DAE.Exp outExp;
  output tuple<list<Absyn.Path>, list<Absyn.Path>> otpl;
algorithm
  (outExp,otpl) := matchcontinue (inExp,itpl)
    local
      Absyn.Path path;
      list<Absyn.Path> acc, filter;
    case (DAE.CALL(path = path, attr = DAE.CALL_ATTR(builtin = false)), (acc, filter))
      equation
        path = Absyn.makeNotFullyQualified(path);
        false = List.isMemberOnTrue(path, filter, Absyn.pathEqual);
      then (inExp, (path::acc, filter));
    case (DAE.REDUCTION(reductionInfo = DAE.REDUCTIONINFO(path = path)), (acc, filter))
      equation
        false = List.isMemberOnTrue(path, {Absyn.IDENT("list"),Absyn.IDENT("listReverse"),Absyn.IDENT("array"),Absyn.IDENT("min"),Absyn.IDENT("max"),Absyn.IDENT("sum"),Absyn.IDENT("product")}, Absyn.pathEqual);
        false = List.isMemberOnTrue(path, filter, Absyn.pathEqual);
      then (inExp, (path::acc, filter));
    case (DAE.PARTEVALFUNCTION(path = path), (acc, filter))
      equation
        path = Absyn.makeNotFullyQualified(path);
        false = List.isMemberOnTrue(path, filter, Absyn.pathEqual);
      then (inExp, (path::acc, filter));
    case (DAE.CREF(ty = DAE.T_FUNCTION_REFERENCE_FUNC(builtin = false)), (acc, filter))
      equation
        path = Absyn.crefToPath(getCrefFromExp(inExp));
        false = List.isMemberOnTrue(path, filter, Absyn.pathEqual);
      then (inExp, (path::acc, filter));
    else (inExp,itpl);
  end matchcontinue;
end matchNonBuiltinCallsAndFnRefPaths;

protected function matchMetarecordCalls "Used together with getMatchingExps"
  input DAE.Exp e;
  input list<DAE.Exp> acc;
  output DAE.Exp outExp;
  output list<DAE.Exp> outExps;
algorithm
  (outExp,outExps) := matchcontinue (e,acc)
    local
      Integer index;
    case (DAE.METARECORDCALL(index = index), _)
      equation
        outExps = List.consOnTrue(-1 <> index, e, acc);
      then (e, outExps);
    else (e,acc);
  end matchcontinue;
end matchMetarecordCalls;

protected function generateExtFunctionIncludes "by investigating the annotation of an external function."
  input Absyn.Program program;
  input Absyn.Path path;
  input Option<SCode.Annotation> inAbsynAnnotationOption;
  output list<String> includes;
  output list<String> includeDirs;
  output list<String> libs;
  output list<String> paths;
  output Boolean dynamcLoad;
algorithm
  (includes, includeDirs, libs,paths, dynamcLoad):=
  match (program, path, inAbsynAnnotationOption)
    local
      SCode.Mod mod;
      Boolean b;
      String target;

    case (_, _, SOME(SCode.ANNOTATION(mod)))
      equation
        b = generateExtFunctionDynamicLoad(mod);
        target = Flags.getConfigString(Flags.TARGET);
        libs = generateExtFunctionIncludesLibstr(target,mod);
        includes = generateExtFunctionIncludesIncludestr(mod);
        libs = generateExtFunctionLibraryDirectoryFlags(program, path, mod, libs);
        paths = generateExtFunctionLibraryDirectoryPaths(program, path, mod);
        includeDirs = generateExtFunctionIncludeDirectoryFlags(program, path, mod, includes);
      then
        (includes, includeDirs, libs,paths, b);
    case (_, _, NONE()) then ({}, {}, {},{}, false);
  end match;
end generateExtFunctionIncludes;

protected function generateExtFunctionIncludeDirectoryFlags
  "Process LibraryDirectory and IncludeDirectory"
  input Absyn.Program program;
  input Absyn.Path path;
  input SCode.Mod inMod;
  input list<String> includes;
  output list<String> outDirs;
algorithm
  outDirs := matchcontinue (program, path, inMod, includes)
    local
      String str,istr;
    case (_, _, _, {}) then {};
    case (_, _, _, _)
      equation
        SCode.MOD(binding = SOME((Absyn.STRING(str), _))) =
          Mod.getUnelabedSubMod(inMod, "IncludeDirectory");
        str = CevalScript.getFullPathFromUri(program, str, false);
        istr = "\"-I"+str+"\"";
      then if System.directoryExists(str) then {istr} else {};
    case (_, _, _, _)
      equation
        str = "modelica://" + Absyn.pathFirstIdent(path) + "/Resources/Include";
        str = CevalScript.getFullPathFromUri(program, str, false);
        istr = "\"-I"+str+"\"";
      then if System.directoryExists(str) then {istr} else {};
        // Read SourceInfo instead?
    else {};
  end matchcontinue;
end generateExtFunctionIncludeDirectoryFlags;

protected function generateExtFunctionLibraryDirectoryFlags
  "Process LibraryDirectory and IncludeDirectory"
  input Absyn.Program program;
  input Absyn.Path path;
  input SCode.Mod inMod;
  input list<String> inLibs;
  output list<String> outLibs;
algorithm
  outLibs := matchcontinue (program, path, inMod, inLibs)
    local
      String str, str1, str2, str3, platform1, platform2,target;
      list<String> libs;
      Boolean isLinux;
    case (_, _, _, {}) then {};
    case (_, _, _, libs)
      equation
        SCode.MOD(binding = SOME((Absyn.STRING(str), _))) =
          Mod.getUnelabedSubMod(inMod, "LibraryDirectory");
        str = CevalScript.getFullPathFromUri(program, str, false);
        platform1 = System.openModelicaPlatform();
        platform2 = System.modelicaPlatform();
        isLinux = stringEq("linux",System.os());
        target = Flags.getConfigString(Flags.TARGET);
        // please, take care about ordering these libraries, the most specific should go first (in reverse here)
        libs = generateExtFunctionLibraryDirectoryFlags2(true, str, isLinux, libs,target);
        libs = generateExtFunctionLibraryDirectoryFlags2(not stringEq(platform2,""), str + "/" + platform2, isLinux, libs,target);
        libs = generateExtFunctionLibraryDirectoryFlags2(not stringEq(platform1,""), str + "/" + platform1, isLinux, libs,target);
      then libs;
    case (_, _, _, libs)
      equation
        str = "modelica://" + Absyn.pathFirstIdent(path) + "/Resources/Library";
        str = CevalScript.getFullPathFromUri(program, str, false);
        platform1 = System.openModelicaPlatform();
        platform2 = System.modelicaPlatform();
        isLinux = stringEq("linux",System.os());
        target = Flags.getConfigString(Flags.TARGET);
        // please, take care about ordering these libraries, the most specific should go first (in reverse here)
        libs = generateExtFunctionLibraryDirectoryFlags2(true, str, isLinux, libs,target);
        libs = generateExtFunctionLibraryDirectoryFlags2(not stringEq(platform2,""), str + "/" + platform2, isLinux, libs,target);
        libs = generateExtFunctionLibraryDirectoryFlags2(not stringEq(platform1,""), str + "/" + platform1, isLinux, libs,target);
      then libs;
    else inLibs;
  end matchcontinue;
end generateExtFunctionLibraryDirectoryFlags;

protected function generateExtFunctionLibraryDirectoryFlags2
  input Boolean add;
  input String dir;
  input Boolean isLinux;
  input list<String> inLibs;
   input String target;
  output list<String> libs;
algorithm
  libs := match (add,dir,isLinux,inLibs,target)
    local
      Boolean b;
    case (true,_,_,libs,"msvc")
      equation
        b = System.directoryExists(dir);
        libs = List.consOnTrue(b, "/LIBPATH:\"" + dir + "\"", libs);
        libs = List.consOnTrue(b and isLinux, "-Wl,-rpath=\"" + dir + "\"", libs);
      then libs;
    case (true,_,_,libs,_)
      equation
        b = System.directoryExists(dir);
        libs = List.consOnTrue(b, "\"-L" + dir + "\"", libs);
        libs = List.consOnTrue(b and isLinux, "-Wl,-rpath=\"" + dir + "\"", libs);
      then libs;
    else inLibs;
  end match;
end generateExtFunctionLibraryDirectoryFlags2;


protected function generateExtFunctionLibraryDirectoryPaths
  "Process LibraryDirectory and IncludeDirectory"
  input Absyn.Program program;
  input Absyn.Path path;
  input SCode.Mod inMod;
  output list<String> outLibs;
algorithm
  outLibs := matchcontinue (program, path, inMod)
    local
      String str, str1, str2, str3, platform1, platform2,target;
      list<String> libs;
      Boolean isLinux;
    case (_, _, _)
      equation
        SCode.MOD(binding = SOME((Absyn.STRING(str), _))) =
          Mod.getUnelabedSubMod(inMod, "LibraryDirectory");
        str = CevalScript.getFullPathFromUri(program, str, false);
        platform1 = System.openModelicaPlatform();
        platform2 = System.modelicaPlatform();
        isLinux = stringEq("linux",System.os());
        // please, take care about ordering these libraries, the most specific should go first (in reverse here)
        libs = generateExtFunctionLibraryDirectoryPaths2(true, str, isLinux, {} );
        libs = generateExtFunctionLibraryDirectoryPaths2(not stringEq(platform2,""), str + "/" + platform2, isLinux, libs);
        libs = generateExtFunctionLibraryDirectoryPaths2(not stringEq(platform1,""), str + "/" + platform1, isLinux, libs);
      then libs;
    case (_, _, _)
      equation
        str = "modelica://" + Absyn.pathFirstIdent(path) + "/Resources/Library";
        str = CevalScript.getFullPathFromUri(program, str, false);
        platform1 = System.openModelicaPlatform();
        platform2 = System.modelicaPlatform();
        isLinux = stringEq("linux",System.os());
        // please, take care about ordering these libraries, the most specific should go first (in reverse here)
        libs = generateExtFunctionLibraryDirectoryPaths2(true, str, isLinux, {} );
        libs = generateExtFunctionLibraryDirectoryPaths2(not stringEq(platform2,""), str + "/" + platform2, isLinux, libs);
        libs = generateExtFunctionLibraryDirectoryPaths2(not stringEq(platform1,""), str + "/" + platform1, isLinux, libs);
      then libs;
    else {};
  end matchcontinue;
end generateExtFunctionLibraryDirectoryPaths;


protected function generateExtFunctionLibraryDirectoryPaths2
  input Boolean add;
  input String dir;
  input Boolean isLinux;
  input list<String> inLibs;
  output list<String> libs;
algorithm
  libs := match (add,dir,isLinux,inLibs)
    local
      Boolean b;
    case (true,_,_,libs)
      equation
        b = System.directoryExists(dir);
        libs = List.consOnTrue(b, dir , libs);
       then libs;
   else inLibs;
  end match;
end generateExtFunctionLibraryDirectoryPaths2;


protected function getLibraryStringInMSVCFormat
"Takes an Absyn.STRING describing a library and outputs a list
of strings corresponding to it.
Note: Normally only outputs a single string, but Lapack on MinGW is special."
  input Absyn.Exp exp;
  output list<String> strs;
algorithm
  strs := matchcontinue exp
    local
      String str;

    // seems lapack can show on Lapack form or lapack (different case) (MLS revision 6155)
    case Absyn.STRING("lapack")
      then getLibraryStringInMSVCFormat(Absyn.STRING("Lapack"));

    // Lapack on MinGW/Windows is linked against f2c
    case Absyn.STRING("Lapack")
      then {"lapack_win32_MT.lib", "f2c.lib"};

    // omcruntime on windows needs linking with mico2313 and wsock and then some :)
    case Absyn.STRING("omcruntime")
      equation
        true = "Windows_NT" == System.os();
        strs = {"f2c.lib", "initialization.lib", "libexpat.lib", "math-support.lib", "meta.lib", "ModelicaExternalC.lib", "results.lib", "simulation.lib", "solver.lib", "sundials_kinsol.lib", "sundials_nvecserial.lib", "util.lib", "lapack_win32_MT.lib"};
      then
        strs;

    // Wonder if there may be issues if we have duplicates in the Corba libs
    // and the other libs. Some other developer will probably swear over this
    // hack some day, but at least I get an early weekend.
    case Absyn.STRING("OpenModelicaCorba")
      equation
        str = System.getCorbaLibs();
      then {str};

    // If the string starts with a -, it's probably -l or -L gcc flags
    case Absyn.STRING(str)
      equation
        true = "-" == stringGetStringChar(str, 1);
      then {str};

    case Absyn.STRING(str)
      equation
        str = str + ".lib";
      then {str};

    case _
      equation
        Error.addMessage(Error.INTERNAL_ERROR, {"Failed to process Library annotation for external function"});
      then fail();
  end matchcontinue;
end getLibraryStringInMSVCFormat;

protected function getLibraryStringInGccFormat
"Takes an Absyn.STRING describing a library and outputs a list
of strings corresponding to it.
Note: Normally only outputs a single string, but Lapack on MinGW is special."
  input Absyn.Exp exp;
  output list<String> strs;
algorithm
  strs := matchcontinue exp
    local
      String str, fopenmp;

    // Lapack is always included
    case Absyn.STRING("lapack") then {};
    case Absyn.STRING("Lapack") then {};

    // omcruntime on windows needs linking with mico2313 and wsock and then some :)
    case Absyn.STRING(str as "omcruntime")
      equation
        true = "Windows_NT" == System.os();
        str = "-l" + str;
        strs = str :: "-lintl" :: "-liconv" :: "-lexpat" :: "-lsqlite3" :: "-llpsolve55" :: "-lmico2313" :: "-lws2_32" :: "-lregex" :: {};
      then  strs;

    // Wonder if there may be issues if we have duplicates in the Corba libs
    // and the other libs. Some other developer will probably swear over this
    // hack some day, but at least I get an early weekend.
    case Absyn.STRING("OpenModelicaCorba")
      equation
        str = System.getCorbaLibs();
      then {str};

    // If omcruntime is linked statically against omniORB, we need to include those here as well
    case Absyn.STRING("omcruntime")
      equation
        false = "Windows_NT" == System.os();
      then
        System.getRuntimeLibs();

    // If the string is a file, return it as it is
    case Absyn.STRING(str)
      equation
        true = System.regularFileExists(str);
      then {str};

    // If the string starts with a -, it's probably -l or -L gcc flags
    case Absyn.STRING(str)
      equation
        true = "-" == stringGetStringChar(str, 1);
      then {str};

    case Absyn.STRING(str)
      equation
        str = "-l" + str;
      then {str};

    case _
      equation
        Error.addMessage(Error.INTERNAL_ERROR, {"Failed to process Library annotation for external function"});
      then fail();
  end matchcontinue;
end getLibraryStringInGccFormat;

protected function generateExtFunctionIncludesLibstr
  input String target;
  input SCode.Mod inMod;
  output list<String> outStringLst;
algorithm
  outStringLst:= matchcontinue (target,inMod)
    local
      list<Absyn.Exp> arr;
      list<String> libs;
      list<list<String>> libsList;
      Absyn.Exp exp;
    case ("msvc",_)
      equation
        SCode.MOD(binding = SOME((Absyn.ARRAY(arr), _))) =
          Mod.getUnelabedSubMod(inMod, "Library");
        libsList = List.map(arr, getLibraryStringInMSVCFormat);
      then
        List.flatten(libsList);
    case ("msvc",_)
      equation
        SCode.MOD(binding = SOME((exp, _))) =
          Mod.getUnelabedSubMod(inMod, "Library");
        libs = getLibraryStringInMSVCFormat(exp);
      then
        libs;
    case (_,_)
      equation
        SCode.MOD(binding = SOME((Absyn.ARRAY(arr), _))) =
          Mod.getUnelabedSubMod(inMod, "Library");
        libsList = List.map(arr, getLibraryStringInGccFormat);
      then
        List.flatten(libsList);
    case (_,_)
      equation
        SCode.MOD(binding = SOME((exp, _))) =
          Mod.getUnelabedSubMod(inMod, "Library");
        libs = getLibraryStringInGccFormat(exp);
      then
        libs;
    else {};
  end matchcontinue;
end generateExtFunctionIncludesLibstr;

protected function generateExtFunctionIncludesIncludestr
  input SCode.Mod inMod;
  output list<String> includes;
algorithm
  includes := matchcontinue (inMod)
    local
      String inc, inc_1;
      Integer lineNumberStart;
      String str,fileName;
    case (_)
      equation
        SCode.MOD(binding = SOME((Absyn.STRING(inc), _)), info = SOURCEINFO(fileName=fileName,lineNumberStart=lineNumberStart)) =
          Mod.getUnelabedSubMod(inMod, "Include");
        str = "#line "+intString(lineNumberStart)+" \""+fileName+"\"";
        inc_1 = System.unescapedString(inc);
        includes = if Config.acceptMetaModelicaGrammar() or Flags.isSet(Flags.GEN_DEBUG_SYMBOLS) then {str,inc_1} else {inc_1};
      then includes;
    else {};
  end matchcontinue;
end generateExtFunctionIncludesIncludestr;

protected function generateExtFunctionDynamicLoad
  input SCode.Mod inMod;
  output Boolean outDynamicLoad;
algorithm
  outDynamicLoad:= matchcontinue (inMod)
    local
      Boolean b;
    case (_)
      equation
        SCode.MOD(binding = SOME((Absyn.BOOL(b), _))) =
          Mod.getUnelabedSubMod(inMod, "DynamicLoad");
      then
        b;
    else false;
  end matchcontinue;
end generateExtFunctionDynamicLoad;

public function getImplicitRecordConstructors
  "If a record instance is sent to a function we need to generate code for the
  record constructor even if it's not explicitly called, because the constructor
  is used by the generated code. This function checks the arguments of a
  function for these implicit record constructor calls and returns a list of all
  record constructors that are used."
  input list<DAE.Exp> inExpLst;
  output list<DAE.Exp> outExpLst;
algorithm
  outExpLst := matchcontinue(inExpLst)
    local
      DAE.ComponentRef cref;
      DAE.Type record_type;
      Absyn.Path record_path;
      list<DAE.Exp> rest_expr;
      DAE.Exp record_cref;
    case ({}) then {};
      // A record component reference.
    case (DAE.CREF(
      componentRef = cref,
      ty = (DAE.T_COMPLEX(
        complexClassType = ClassInf.RECORD(path = record_path)))) :: rest_expr)
      equation
        // Make sure it has no subscripts, i.e. it's a component reference for
        // an entire record instance.
        {} = ComponentReference.crefLastSubs(cref);
        // Build a DAE.CREF from the record path.
        cref = ComponentReference.pathToCref(record_path);
        record_cref = Expression.crefExp(cref);
        rest_expr = getImplicitRecordConstructors(rest_expr);
      then record_cref :: rest_expr;
    case (_ :: rest_expr)
      equation
        rest_expr = getImplicitRecordConstructors(rest_expr);
      then rest_expr;
  end matchcontinue;
end getImplicitRecordConstructors;

protected function addDivExpErrorMsgtoExp "author: Frenkel TUD 2010-02, Adds the error msg to Expression.Div."
  input DAE.Exp inExp;
  input DAE.ElementSource inSource;
  output DAE.Exp outExp;
algorithm
  outExp := match(inExp, inSource)
    local
      DAE.Exp exp;

    case(_, _)
      equation
        false = Expression.traverseCrefsFromExp(inExp, traversingXLOCExpFinder, false);
        (exp, _) = Expression.traverseExp(inExp, traversingDivExpFinder, inSource);
      then exp;
  end match;
end addDivExpErrorMsgtoExp;

protected function traversingXLOCExpFinder "author: Frenkel TUD 2010-02"
  input DAE.ComponentRef inCref;
  input Boolean inB;
  output Boolean  outB;
algorithm
  outB := match(inCref, inB)
    case( DAE.CREF_IDENT(ident="xloc", identType=DAE.T_ARRAY(dims={DAE.DIM_UNKNOWN()})) , _ )
      then true;
   case(_, _) then inB;
  end match;
end traversingXLOCExpFinder;

protected function traversingDivExpFinder "author: Frenkel TUD 2010-02"
  input DAE.Exp inExp;
  input DAE.ElementSource inSource;
  output DAE.Exp outExp;
  output DAE.ElementSource outSource;
algorithm
  (outExp,outSource) := matchcontinue (inExp,inSource)
    local
      DAE.Exp e, e1, e2;
      DAE.Type ty;
      String se;
      DAE.ElementSource source;
    case (e as DAE.BINARY(operator = DAE.DIV(_), exp2 = e2), source)
      equation
        true = Expression.isConst(e2);
        false = Expression.isZero(e2);
      then (e, source);
    case (DAE.BINARY(exp1 = e1, operator = DAE.DIV(ty), exp2 = e2), source)
      then (DAE.CALL(Absyn.IDENT("DIVISION"), {e1, e2}, DAE.CALL_ATTR(ty, false, true, false, false, DAE.NO_INLINE(), DAE.NO_TAIL())), source);

    case (e as DAE.BINARY(operator = DAE.DIV_ARRAY_SCALAR(_), exp2 = e2), source)
      equation
        true = Expression.isConst(e2);
        false = Expression.isZero(e2);
      then (e, source);
    case (DAE.BINARY(exp1 = e1, operator = DAE.DIV_ARRAY_SCALAR(ty), exp2 = e2), source)
      then (DAE.CALL(Absyn.IDENT("DIVISION_ARRAY_SCALAR"), {e1, e2}, DAE.CALL_ATTR(ty, false, true, false, false, DAE.NO_INLINE(), DAE.NO_TAIL())), source);

    case (e as DAE.BINARY(operator = DAE.DIV_SCALAR_ARRAY(_), exp2 = e2), source)
      equation
        true = Expression.isConst(e2);
        false = Expression.isZero(e2);
      then (e, source);
    case (DAE.BINARY(exp1 = e1, operator = DAE.DIV_SCALAR_ARRAY(ty), exp2 = e2), source)
      then (DAE.CALL(Absyn.IDENT("DIVISION_SCALAR_ARRAY"), {e1, e2}, DAE.CALL_ATTR(ty, false, true, false, false, DAE.NO_INLINE(), DAE.NO_TAIL())), source);
    else (inExp,inSource);
  end matchcontinue;
end traversingDivExpFinder;

protected function addDivExpErrorMsgtosimJac "helper for addDivExpErrorMsgtoSimEqSystem."
  input tuple<Integer, Integer, SimCode.SimEqSystem> inJac;
  output tuple<Integer, Integer, SimCode.SimEqSystem> outJac;
algorithm
  outJac := match inJac
    local
      Integer a, b;
      SimCode.SimEqSystem ses;
    case ((a, b, ses))
      equation
        ses = addDivExpErrorMsgtoSimEqSystem(ses);
      then
        ((a, b, ses));
  end match;
end addDivExpErrorMsgtosimJac;

protected function addDivExpErrorMsgtoSimEqSystem "Traverses all subexpressions of an expression of an equation."
  input SimCode.SimEqSystem inSES;
  output SimCode.SimEqSystem outSES;
algorithm
  outSES:=
  matchcontinue (inSES)
    local
      DAE.Exp e;
      DAE.ComponentRef cr;
      Boolean partOfMixed;
      list<SimCodeVar.SimVar> vars;
      list<DAE.Exp> elst, elst1;
      list<tuple<Integer, Integer, SimCode.SimEqSystem>> simJac, simJac1;
      Integer index, indexSys;
      list<DAE.ComponentRef> crefs;
      SimCode.SimEqSystem cont, cont1, elseWhenEq, elseWhen;
      list<SimCode.SimEqSystem> discEqs, discEqs1;
      list<DAE.ComponentRef> conditions;
      Boolean initialCall;
      DAE.ElementSource source;
      Option<SimCode.JacobianMatrix> symJac;
      Boolean linearTearing;
      list<DAE.ElementSource> sources;
      Boolean homotopySupport;
      Boolean mixedSystem;

    case SimCode.SES_RESIDUAL(index= index, exp = e, source = source)
      equation
        e = addDivExpErrorMsgtoExp(e, source);
      then
        SimCode.SES_RESIDUAL(index, e, source);
    case SimCode.SES_SIMPLE_ASSIGN(index= index, cref = cr, exp = e, source = source)
      equation
        e = addDivExpErrorMsgtoExp(e, source);
      then
        SimCode.SES_SIMPLE_ASSIGN(index, cr, e, source);
    case SimCode.SES_ARRAY_CALL_ASSIGN(index = index, componentRef = cr, exp = e, source = source)
      equation
        e = addDivExpErrorMsgtoExp(e, source);
      then
        SimCode.SES_ARRAY_CALL_ASSIGN(index, cr, e, source);
        /*
         case (SimCode.SES_ALGORITHM(), inDlowMode)
         equation
         e = addDivExpErrorMsgtoExp(e, (source, inDlowMode));
         then
         SimCode.SES_ALGORITHM();
         */
    case SimCode.SES_LINEAR(index, partOfMixed, vars, elst, simJac, discEqs, symJac, sources, indexSys)
      equation
        simJac1 = List.map(simJac, addDivExpErrorMsgtosimJac);
        elst1 = List.map1(elst, addDivExpErrorMsgtoExp, DAE.emptyElementSource);
      then
        SimCode.SES_LINEAR(index, partOfMixed, vars, elst1, simJac1, discEqs, symJac, sources, indexSys);

    case SimCode.SES_NONLINEAR(index=index, eqs=discEqs, crefs=crefs, indexNonLinearSystem=indexSys, jacobianMatrix=symJac, linearTearing=linearTearing, homotopySupport=homotopySupport, mixedSystem=mixedSystem)
      equation
        discEqs =  List.map(discEqs, addDivExpErrorMsgtoSimEqSystem);
      then
        SimCode.SES_NONLINEAR(index, discEqs, crefs, indexSys, symJac, linearTearing, homotopySupport, mixedSystem);

    case SimCode.SES_MIXED(index, cont, vars, discEqs, indexSys)
      equation
        cont1 = addDivExpErrorMsgtoSimEqSystem(cont);
        discEqs1 = List.map(discEqs, addDivExpErrorMsgtoSimEqSystem);
      then
        SimCode.SES_MIXED(index, cont1, vars, discEqs1, indexSys);

    case SimCode.SES_WHEN(index=index, conditions=conditions, initialCall=initialCall, left=cr, right=e, elseWhen= NONE(), source=source)
      equation
        e = addDivExpErrorMsgtoExp(e, source);
      then
        SimCode.SES_WHEN(index, conditions, initialCall, cr, e, NONE(), source);

    case SimCode.SES_WHEN(index=index, conditions=conditions, initialCall=initialCall, left=cr, right=e, elseWhen= SOME(elseWhen), source=source)
      equation
        e = addDivExpErrorMsgtoExp(e, source);
        elseWhenEq = addDivExpErrorMsgtoSimEqSystem(elseWhen);
      then
        SimCode.SES_WHEN(index, conditions, initialCall, cr, e, SOME(elseWhenEq), source);
    else inSES;
  end matchcontinue;
end addDivExpErrorMsgtoSimEqSystem;

protected function addDivExpErrorMsgtoSimEqSystemTuple
  input tuple<SimCode.SimEqSystem,Integer> inSES;
  output tuple<SimCode.SimEqSystem, Integer> outSES;

protected
  Integer sccIdx;
  SimCode.SimEqSystem eqSyst;

algorithm
  (eqSyst,sccIdx) := inSES;
  eqSyst := addDivExpErrorMsgtoSimEqSystem(eqSyst);
  outSES := (eqSyst,sccIdx);

end addDivExpErrorMsgtoSimEqSystemTuple;

protected function extractVarUnit "author: asodja, 2010-03-11
  Extract variable's unit and displayUnit as strings from
  DAE.VariablesAttributes structures."
  input Option<DAE.VariableAttributes> var_attr;
  output String unitStr;
  output String displayUnitStr;
algorithm
  (unitStr, displayUnitStr) := matchcontinue(var_attr)
    local
      DAE.Exp uexp, duexp;
    case ( SOME(DAE.VAR_ATTR_REAL(unit = SOME(uexp), displayUnit = SOME(duexp) )) )
      equation
        unitStr = ExpressionDump.printExpStr(uexp);
        unitStr = System.stringReplace(unitStr, "\"", "");
        unitStr = System.stringReplace(unitStr, "\\", "\\\\");
        displayUnitStr = ExpressionDump.printExpStr(duexp);
        displayUnitStr = System.stringReplace(displayUnitStr, "\"", "");
        displayUnitStr = System.stringReplace(displayUnitStr, "\\", "\\\\");
      then (unitStr, displayUnitStr);
    case ( SOME(DAE.VAR_ATTR_REAL(unit = SOME(uexp), displayUnit = NONE())) )
      equation
        unitStr = ExpressionDump.printExpStr(uexp);
        unitStr = System.stringReplace(unitStr, "\"", "");
        unitStr = System.stringReplace(unitStr, "\\", "\\\\");
      then (unitStr, unitStr);
    case (_)
    then ("", "");
  end matchcontinue;
end extractVarUnit;

protected function getMinMaxValues "extract min/max values from BackendDAE.Variable"
  input BackendDAE.Var inDAELowVar;
  output Option<DAE.Exp> outMinValue;
  output Option<DAE.Exp> outMaxValue;
algorithm
  (outMinValue, outMaxValue) := matchcontinue(inDAELowVar)
    local
      Option<DAE.VariableAttributes> dae_var_attr;
      DAE.Exp minValue, maxValue;

    case(BackendDAE.VAR(varType=DAE.T_REAL(), values=dae_var_attr)) equation
      (SOME(minValue), SOME(maxValue)) = DAEUtil.getMinMaxValues(dae_var_attr);
      // lochel: #2597
      // true = Expression.isConstValue(minValue);
      // true = Expression.isConstValue(maxValue);
    then (SOME(minValue), SOME(maxValue));

    case(BackendDAE.VAR(varType=DAE.T_REAL(), values=dae_var_attr)) equation
      (SOME(minValue), NONE()) = DAEUtil.getMinMaxValues(dae_var_attr);
      // lochel: #2597
      // true = Expression.isConstValue(minValue);
    then (SOME(minValue), NONE());

    case(BackendDAE.VAR(varType=DAE.T_REAL(), values=dae_var_attr)) equation
      (NONE(), SOME(maxValue)) = DAEUtil.getMinMaxValues(dae_var_attr);
      // lochel: #2597
      // true = Expression.isConstValue(maxValue);
    then (NONE(), SOME(maxValue));

    else (NONE(), NONE());
  end matchcontinue;
end getMinMaxValues;

protected function getStartValue "Extract initial value from BackendDAE.Variable, if it has any"
  input BackendDAE.Var daelowVar;
  output Option<DAE.Exp> initVal;
algorithm
  initVal := matchcontinue(daelowVar)
    local
      Option<DAE.VariableAttributes> dae_var_attr;
      Values.Value value;
      DAE.Exp e;

    case (BackendDAE.VAR(varKind = BackendDAE.VARIABLE(), bindValue = SOME(value))) equation
      e = ValuesUtil.valueExp(value);
      // lochel: #2597
      // true = Expression.isConstValue(e);
    then SOME(e);

    case (BackendDAE.VAR(varKind = BackendDAE.VARIABLE(), varType = DAE.T_STRING(), values = dae_var_attr)) equation
      e = DAEUtil.getStartAttrFail(dae_var_attr);
      // lochel: #2597
      // true = Expression.isConstValue(e);
    then SOME(e);

    case (BackendDAE.VAR(varKind = BackendDAE.VARIABLE(), values = dae_var_attr)) equation
      e = DAEUtil.getStartAttrFail(dae_var_attr);
      // lochel: #2597
      // true = Expression.isConstValue(e);
    then SOME(e);

    case (BackendDAE.VAR(varKind = BackendDAE.DISCRETE(), bindValue = SOME(value))) equation
      e = ValuesUtil.valueExp(value);
      // lochel: #2597
      // true = Expression.isConstValue(e);
    then SOME(e);

    case (BackendDAE.VAR(varKind = BackendDAE.DISCRETE(), values = dae_var_attr)) equation
      e = DAEUtil.getStartAttrFail(dae_var_attr);
      // lochel: #2597
      // true = Expression.isConstValue(e);
    then SOME(e);

    case (BackendDAE.VAR(varKind = BackendDAE.STATE(), values = dae_var_attr)) equation
      e = DAEUtil.getStartAttrFail(dae_var_attr);
      // lochel: #2597
      // true = Expression.isConstValue(e);
    then SOME(e);

    case (BackendDAE.VAR(varKind = BackendDAE.DUMMY_DER(), bindValue = SOME(value))) equation
      e = ValuesUtil.valueExp(value);
      // lochel: #2597
      // true = Expression.isConstValue(e);
    then SOME(e);

    case (BackendDAE.VAR(varKind = BackendDAE.DUMMY_DER(), values = dae_var_attr)) equation
      e = DAEUtil.getStartAttrFail(dae_var_attr);
      // lochel: #2597
      // true = Expression.isConstValue(e);
    then SOME(e);

    case (BackendDAE.VAR(varKind = BackendDAE.DUMMY_STATE(), bindValue = SOME(value))) equation
      e = ValuesUtil.valueExp(value);
      // lochel: #2597
      // true = Expression.isConstValue(e);
    then SOME(e);

    case (BackendDAE.VAR(varKind = BackendDAE.DUMMY_STATE(), values = dae_var_attr)) equation
      e = DAEUtil.getStartAttrFail(dae_var_attr);
      // lochel: #2597
      // true = Expression.isConstValue(e);
    then SOME(e);

    case (BackendDAE.VAR(varKind = BackendDAE.PARAM(), varType = DAE.T_STRING(), bindValue = SOME(value))) equation
      e = ValuesUtil.valueExp(value);
      // lochel: #2597
      // true = Expression.isConstValue(e);
    then SOME(e);

    case (BackendDAE.VAR(varKind = BackendDAE.PARAM(), bindValue = SOME(value))) equation
      e = ValuesUtil.valueExp(value);
      // lochel: #2597
      // true = Expression.isConstValue(e);
    then SOME(e);

    /* String - Parameters without value binding. Investigate if it has start value */
    case (BackendDAE.VAR(varKind = BackendDAE.PARAM(), varType = DAE.T_STRING(), bindValue = NONE(), values = dae_var_attr)) equation
      e = DAEUtil.getStartAttrFail(dae_var_attr);
      // lochel: #2597
      // true = Expression.isConstValue(e);
    then SOME(e);

    /* Parameters without value binding. Investigate if it has start value */
    case (BackendDAE.VAR(varKind = BackendDAE.PARAM(), bindValue = NONE(), values = dae_var_attr)) equation
      e = DAEUtil.getStartAttrFail(dae_var_attr);
      // lochel: #2597
      // true = Expression.isConstValue(e);
    then SOME(e);

    case (BackendDAE.VAR(varKind = BackendDAE.EXTOBJ(_), bindExp = SOME(e)))
    then SOME(e);

    case (_)
    then NONE();
  end matchcontinue;
end getStartValue;

protected function getNominalValue "Extract nominal value from BackendDAE.Variable, if it has any"
  input BackendDAE.Var daelowVar;
  output Option<DAE.Exp> nomVal;
algorithm
  nomVal := matchcontinue(daelowVar)
    local
      Option<DAE.VariableAttributes> dae_var_attr;
      DAE.Exp e;

    case (BackendDAE.VAR(varType = DAE.T_REAL(), values = dae_var_attr)) equation
      e = DAEUtil.getNominalAttrFail(dae_var_attr);
      // lochel: #2597
      // true = Expression.isConstValue(e);
    then SOME(e);

    case (_)
    then NONE();
  end matchcontinue;
end getNominalValue;


/****** HashTable ComponentRef -> SimCodeVar.SimVar ******/
/* a workaround to enable "cross public import" */


/* HashTable instance specific code */

protected function keyEqual
  input SimCode.Key key1;
  input SimCode.Key key2;
  output Boolean res;
algorithm
  res := ComponentReference.crefEqualNoStringCompare(key1, key2);
end keyEqual;

/* end of HashTable instance specific code */


/*
 public function cloneHashTable "
 Author BZ 2008-06
 Make a stand-alone-copy of hashtable.
 "
 input HashTableCrefToSimVar inHash;
 output HashTableCrefToSimVar outHash;
 algorithm outHash := matchcontinue(inHash)
 local
 array<list<tuple<Key, Integer>>> arg1, arg1_2;
 Integer arg3, arg4, arg3_2, arg4_2, arg21, arg21_2, arg22, arg22_2;
 array<Option<tuple<Key, Value>>> arg23, arg23_2;
 case(HASHTABLE(arg1, VALUE_ARRAY(arg21, arg22, arg23), arg3, arg4))
 equation
 arg1_2 = arrayCopy(arg1);
 arg21_2 = arg21;
 arg22_2 = arg22;
 arg23_2 = arrayCopy(arg23);
 arg3_2 = arg3;
 arg4_2 = arg4;
 then
 HASHTABLE(arg1_2, VALUE_ARRAY(arg21_2, arg22_2, arg23_2), arg3_2, arg4_2);
 end matchcontinue;
 end cloneHashTable;

 public function nullHashTable "
 author: PA

 Returns an empty HashTable.
 Using the bucketsize 100 and array size 10.
 "
 output HashTableCrefToSimVar hashTable;
 array<list<tuple<Key, Integer>>> arr;
 list<Option<tuple<Key, Value>>> lst;
 array<Option<tuple<Key, Value>>> emptyarr;
 algorithm
 arr := fill({}, 0);
 emptyarr := listArray({});
 hashTable := HASHTABLE(arr, VALUE_ARRAY(0, 0, emptyarr), 0, 0);
 end nullHashTable;
 */

protected function emptyHashTableSized "
  author: PA
  Returns an empty HashTable.
  Using the bucketsize 100 and array size 10."
  input Integer size;
  output SimCode.HashTableCrefToSimVar hashTable;
protected
  array<list<tuple<SimCode.Key, Integer>>> arr;
  list<Option<tuple<SimCode.Key, SimCode.Value>>> lst;
  array<Option<tuple<SimCode.Key, SimCode.Value>>> emptyarr;
  Integer szArr;
algorithm
  arr := arrayCreate(size, {});
  emptyarr := arrayCreate(size, NONE());
  szArr:=realInt(realMul(intReal(size), 0.6));
  hashTable := SimCode.HASHTABLE(arr, SimCode.VALUE_ARRAY(0, szArr, emptyarr), size, 0);
end emptyHashTableSized;

/*
 public function isEmpty "Returns true if hashtable is empty"
 input HashTableCrefToSimVar hashTable;
 output Boolean res;
 algorithm
 res := matchcontinue(hashTable)
 case(HASHTABLE(_, _, _, 0)) then true;
 case(_) then false;
 end matchcontinue;
 end isEmpty;
 */

public function add "
  author: PA

  Add a Key-Value tuple to hashtable.
  If the Key-Value tuple already exists, the function updates the Value.
"
  input tuple<SimCode.Key, SimCode.Value> entry;
  input SimCode.HashTableCrefToSimVar hashTable;
  output SimCode.HashTableCrefToSimVar outHashTable;
algorithm
  outHashTable := matchcontinue (entry, hashTable)
    local
      Integer  indx, newpos, n, n_1, bsize, indx_1;
      SimCode.ValueArray varr_1, varr;
      list<tuple<SimCode.Key, Integer>> indexes;
      array<list<tuple<SimCode.Key, Integer>>> hashvec_1, hashvec;
      tuple<SimCode.Key, SimCode.Value> v, newv;
      SimCode.Key key;
      SimCode.Value value;
      /* Adding when not existing previously */
    case ((v as (key, _)), (SimCode.HASHTABLE(hashvec, varr, bsize, _)))
      equation
        failure((_) = get(key, hashTable));
        indx = ComponentReference.hashComponentRefMod(key,bsize);
        newpos = valueArrayLength(varr);
        varr_1 = valueArrayAdd(varr, v);
        indexes = hashvec[indx + 1];
        hashvec_1 = arrayUpdate(hashvec, indx + 1, ((key, newpos) :: indexes));
        n_1 = valueArrayLength(varr_1);
      then SimCode.HASHTABLE(hashvec_1, varr_1, bsize, n_1);

        /* adding when already present => Updating value */
    case ((newv as (key, _)), (SimCode.HASHTABLE(hashvec, varr, bsize, n)))
      equation
        (_, indx) = get1(key, hashTable);
        // print("adding when present, indx =" );print(intString(indx));print("\n");
        varr_1 = valueArraySetnth(varr, indx, newv);
      then SimCode.HASHTABLE(hashvec, varr_1, bsize, n);
    case (_, _)
      equation
        print("- HashTableCrefToSimVar.add failed\n");
      then
        fail();
  end matchcontinue;
end add;
/*
 public function anyKeyInHashTable "Returns true if any of the keys are present in the hashtable. Stops and returns true upon first occurence"
 input list<Key> keys;
 input HashTableCrefToSimVar ht;
 output Boolean res;
 algorithm
 res := matchcontinue(keys, ht)
 local Key key;
 case({}, ht) then false;
 case(key::keys, ht) equation
 _ = get(key, ht);
 then true;
 case(_::keys, ht) then anyKeyInHashTable(keys, ht);
 end matchcontinue;
 end anyKeyInHashTable;

 public function addListNoUpd "adds several keys with the same value, using addNuUpdCheck. Can be used to use HashTable as a Set"
 input list<Key> keys;
 input Value v;
 input HashTableCrefToSimVar ht;
 output HashTableCrefToSimVar outHt;
 algorithm
 ht := matchcontinue(keys, v, ht)
 local Key key;
 case ({}, v, ht) then ht;
 case(key::keys, v, ht) equation
 ht = addNoUpdCheck((key, v), ht);
 ht = addListNoUpd(keys, v, ht);
 then ht;
 end matchcontinue;
 end addListNoUpd;
 */
public function addNoUpdCheck "
  author: PA

  Add a Key-Value tuple to hashtable.
  If the Key-Value tuple already exists, the function updates the Value.
"
  input tuple<SimCode.Key, SimCode.Value> entry;
  input SimCode.HashTableCrefToSimVar hashTable;
  output SimCode.HashTableCrefToSimVar outHashTable;
algorithm
  outHashTable := matchcontinue (entry, hashTable)
    local
      Integer hval, indx, newpos, n, n_1, bsize, indx_1;
      SimCode.ValueArray varr_1, varr;
      list<tuple<SimCode.Key, Integer>> indexes;
      array<list<tuple<SimCode.Key, Integer>>> hashvec_1, hashvec;
      String name_str;
      tuple<SimCode.Key, SimCode.Value> v, newv;
      SimCode.Key key;
      SimCode.Value value;

      // adding when not existing previously
    case ((v as (key, _)), SimCode.HASHTABLE(hashvec, varr, bsize, _))
      equation
        indx = ComponentReference.hashComponentRefMod(key,bsize);
        newpos = valueArrayLength(varr);
        varr_1 = valueArrayAdd(varr, v);
        indexes = hashvec[indx + 1];
        hashvec_1 = arrayUpdate(hashvec, indx + 1, ((key, newpos) :: indexes));
        n_1 = valueArrayLength(varr_1);
      then SimCode.HASHTABLE(hashvec_1, varr_1, bsize, n_1);

        // failure
    else
      equation
        print("- HashTableCrefToSimVar.addNoUpdCheck failed\n");
      then
        fail();
  end matchcontinue;
end addNoUpdCheck;
/*
 public function delete "
 author: PA

 delete the Value associatied with Key from the HashTable.
 Note: This function does not delete from the index table, only from the ValueArray.
 This means that a lot of deletions will not make the HashTable more compact, it will still contain
 a lot of incices information.
 "
 input Key key;
 input HashTableCrefToSimVar hashTable;
 output HashTableCrefToSimVar outHahsTable;
 algorithm
 outVariables:=
 matchcontinue (key, hashTable)
 local
 Integer hval, indx, newpos, n, n_1, bsize, indx_1;
 ValueArray varr_1, varr;
 list<tuple<Key, Integer>> indexes;
 array<list<tuple<Key, Integer>>> hashvec_1, hashvec;
 String name_str;
 tuple<Key, Value> v, newv;
 Value value;
 // * adding when already present => Updating value * /
  case (key, (hashTable as HASHTABLE(hashvec, varr, bsize, n)))
  equation
  (_, indx) = get1(key, hashTable);
  indx_1 = indx - 1;
  varr_1 = valueArrayClearnth(varr, indx);
  then HASHTABLE(hashvec, varr_1, bsize, n);
  case (_, hashTable)
  equation
  print("-HashTableCrefToSimVar.delete failed\n");
  print("content:"); dumpHashTable(hashTable);
  then
  fail();
  end matchcontinue;
  end delete;
  */

public function get "
author: PA

   Returns a Value given a Key and a HashTable.
"
  input SimCode.Key key;
  input SimCode.HashTableCrefToSimVar hashTable;
  output SimCode.Value value;
algorithm
  (value, _):= get1(key, hashTable);
end get;

protected function get1 "help function to get"
  input SimCode.Key key;
  input SimCode.HashTableCrefToSimVar hashTable;
  output SimCode.Value value;
  output Integer indx;
algorithm
  (value, indx):=
  match (key, hashTable)
    local
      Integer   bsize, n;
      list<tuple<SimCode.Key, Integer>> indexes;
      SimCode.Value v;
      array<list<tuple<SimCode.Key, Integer>>> hashvec;
      SimCode.ValueArray varr;
      SimCode.Key k;
    case (_, (SimCode.HASHTABLE(hashvec, varr, bsize, _)))
      equation
        indx = ComponentReference.hashComponentRefMod(key,bsize);
        indexes = hashvec[indx + 1];
        indx = get2(key, indexes);
        (k, v) = valueArrayNth(varr, indx);
        true = keyEqual(k, key);
      then
        (v, indx);
  end match;
end get1;

protected function get2 "
 author: PA

  Helper function to get
"
  input SimCode.Key key;
  input list<tuple<SimCode.Key, Integer>> keyIndices;
  output Integer index;
algorithm
  index :=
  matchcontinue (key, keyIndices)
    local
      SimCode.Key key2;
      list<tuple<SimCode.Key, Integer>> xs;
    case (_, ((key2, index) :: _))
      equation
        true = keyEqual(key, key2);
      then
        index;
    case (_, (_ :: xs))
      equation
        index = get2(key, xs);
      then
        index;
  end matchcontinue;
end get2;
/*
 public function hashTableValueList "return the Value entries as a list of Values"
 input HashTableCrefToSimVar hashTable;
 output list<Value> valLst;
 algorithm
 valLst := List.map(hashTableList(hashTable), Util.tuple22);
 end hashTableValueList;

 public function hashTableKeyList "return the Key entries as a list of Keys"
 input HashTableCrefToSimVar hashTable;
 output list<Key> valLst;
 algorithm
 valLst := List.map(hashTableList(hashTable), Util.tuple21);
 end hashTableKeyList;

 public function hashTableList "returns the entries in the hashTable as a list of tuple<Key, Value>"
 input HashTableCrefToSimVar hashTable;
 output list<tuple<Key, Value>> tplLst;
 algorithm
 tplLst := matchcontinue(hashTable)
 local ValueArray varr;
 case(HASHTABLE(valueArr = varr)) equation
 tplLst = valueArrayList(varr);
 then tplLst;
 end matchcontinue;
 end hashTableList;

 public function valueArrayList "
 author: PA
 Transforms a ValueArray to a tuple<Key, Value> list
 "
 input ValueArray valueArray;
 output list<tuple<Key, Value>> tplLst;
 algorithm
 tplLst :=
 matchcontinue (valueArray)
 local
 array<Option<tuple<Key, Value>>> arr;
 tuple<Key, Value> elt;
 Integer lastpos, n, size;
 list<tuple<Key, Value>> lst;
 case (VALUE_ARRAY(numberOfElements = 0, valueArray = arr)) then {};
 case (VALUE_ARRAY(numberOfElements = 1, valueArray = arr))
 equation
 SOME(elt) = arr[0 + 1];
 then
 {elt};
 case (VALUE_ARRAY(numberOfElements = n, arrSize = size, valueArray = arr))
 equation
 lastpos = n - 1;
 lst = valueArrayList2(arr, 0, lastpos);
 then
 lst;
 end matchcontinue;
 end valueArrayList;

 protected function valueArrayList2 "Helper function to valueArrayList"
 input array<Option<tuple<Key, Value>>> inVarOptionArray1;
 input Integer inInteger2;
 input Integer inInteger3;
 output list<tuple<Key, Value>> outVarLst;
 algorithm
 outVarLst:=
 matchcontinue (inVarOptionArray1, inInteger2, inInteger3)
 local
 tuple<Key, Value> v;
 array<Option<tuple<Key, Value>>> arr;
 Integer pos, lastpos, pos_1;
 list<tuple<Key, Value>> res;
 case (arr, pos, lastpos)
 equation
 (pos == lastpos) = true;
 SOME(v) = arr[pos + 1];
 then
 {v};
 case (arr, pos, lastpos)
 equation
 pos_1 = pos + 1;
 SOME(v) = arr[pos + 1];
 res = valueArrayList2(arr, pos_1, lastpos);
 then
 (v :: res);
 case (arr, pos, lastpos)
 equation
 pos_1 = pos + 1;
 NONE = arr[pos + 1];
 res = valueArrayList2(arr, pos_1, lastpos);
 then
 (res);
 end matchcontinue;
 end valueArrayList2;
 */
public function valueArrayLength "
  author: PA

  Returns the number of elements in the ValueArray
"
  input SimCode.ValueArray valueArray;
  output Integer size;
algorithm
  size := match (valueArray)
    case (SimCode.VALUE_ARRAY(numberOfElements = size)) then size;
  end match;
end valueArrayLength;

public function valueArrayAdd "author: PA
  Adds an entry last to the ValueArray, increasing array size
  if no space left by factor 1.4
"
  input SimCode.ValueArray valueArray;
  input tuple<SimCode.Key, SimCode.Value> entry;
  output SimCode.ValueArray outValueArray;
algorithm
  outValueArray:=
  matchcontinue (valueArray, entry)
    local
      Integer n_1, n, size, expandsize, expandsize_1, newsize;
      array<Option<tuple<SimCode.Key, SimCode.Value>>> arr_1, arr, arr_2;
      Real rsize, rexpandsize;
    case (SimCode.VALUE_ARRAY(numberOfElements = n, arrSize = size, valueArray = arr), _)
      equation
        (n < size) = true "Have space to add array elt.";
        n_1 = n + 1;
        arr_1 = arrayUpdate(arr, n + 1, SOME(entry));
      then
        SimCode.VALUE_ARRAY(n_1, size, arr_1);

    case (SimCode.VALUE_ARRAY(numberOfElements = n, arrSize = size, valueArray = arr), _)
      equation
        (n < size) = false "Do NOT have splace to add array elt. Expand with factor 1.4";
        rsize = intReal(size);
        rexpandsize = rsize * 0.4;
        expandsize = realInt(rexpandsize);
        expandsize_1 = intMax(expandsize, 1);
        newsize = expandsize_1 + size;
        arr_1 = Array.expand(expandsize_1, arr, NONE());
        n_1 = n + 1;
        arr_2 = arrayUpdate(arr_1, n + 1, SOME(entry));
      then
        SimCode.VALUE_ARRAY(n_1, newsize, arr_2);
    case (_, _)
      equation
        print("-HashTableCrefToSimVar.valueArrayAdd failed\n");
      then
        fail();
  end matchcontinue;
end valueArrayAdd;

public function valueArraySetnth "author: PA
  Set the n:th variable in the ValueArray to value.
"
  input SimCode.ValueArray valueArray;
  input Integer pos;
  input tuple<SimCode.Key, SimCode.Value> entry;
  output SimCode.ValueArray outValueArray;
algorithm
  outValueArray:=
  matchcontinue (valueArray, pos, entry)
    local
      array<Option<tuple<SimCode.Key, SimCode.Value>>> arr_1, arr;
      Integer n, size;
    case (SimCode.VALUE_ARRAY(n, size, arr), _, _)
      equation
        (pos < size) = true;
        arr_1 = arrayUpdate(arr, pos + 1, SOME(entry));
      then
        SimCode.VALUE_ARRAY(n, size, arr_1);
    case (_, _, _)
      equation
        print("-HashTableCrefToSimVar.valueArraySetnth failed\n");
      then
        fail();
  end matchcontinue;
end valueArraySetnth;
/*
 public function valueArrayClearnth "
 author: PA
 Clears the n:th variable in the ValueArray (set to NONE).
 "
 input ValueArray valueArray;
 input Integer pos;
 output ValueArray outValueArray;
 algorithm
 outValueArray:=
 matchcontinue (valueArray, pos)
 local
 array<Option<tuple<Key, Value>>> arr_1, arr;
 Integer n, size;
 case (VALUE_ARRAY(n, size, arr), pos)
 equation
 (pos < size) = true;
 arr_1 = arrayUpdate(arr, pos + 1, NONE);
 then
 VALUE_ARRAY(n, size, arr_1);
 case (_, _)
 equation
 print("-HashTableCrefToSimVar.valueArrayClearnth failed\n");
 then
 fail();
 end matchcontinue;
 end valueArrayClearnth;
 */
public function valueArrayNth "author: PA

  Retrieve the n:th Vale from ValueArray, index from 0..n-1.
 "
  input SimCode.ValueArray valueArray;
  input Integer pos;
  output SimCode.Key key;
  output SimCode.Value value;
algorithm
  (key, value) :=
  matchcontinue (valueArray, pos)
    local
      SimCode.Key k;
      SimCode.Value v;
      Integer n;
      array<Option<tuple<SimCode.Key, SimCode.Value>>> arr;
    case (SimCode.VALUE_ARRAY(numberOfElements = n, valueArray = arr), _)
      equation
        (pos < n) = true;
        SOME((k, v)) = arr[pos + 1];
      then
        (k, v);
    case (SimCode.VALUE_ARRAY(numberOfElements = n, valueArray = arr), _)
      equation
        (pos < n) = true;
        NONE() = arr[pos + 1];
      then
        fail();
  end matchcontinue;
end valueArrayNth;


/***** end of HashTable ComponentRef -> SimCodeVar.SimVar *******/

public function functionInfo
  input SimCode.Function fn;
  output SourceInfo info;
algorithm
  info := match fn
    case SimCode.FUNCTION(info = info) then info;
    case SimCode.EXTERNAL_FUNCTION(info = info) then info;
    case SimCode.RECORD_CONSTRUCTOR(info = info) then info;
  end match;
end functionInfo;

public function functionPath
  input SimCode.Function fn;
  output Absyn.Path name;
algorithm
  name := match fn
    case SimCode.FUNCTION(name=name) then name;
    case SimCode.EXTERNAL_FUNCTION(name=name) then name;
    case SimCode.RECORD_CONSTRUCTOR(name=name) then name;
  end match;
end functionPath;

public function eqInfo
  input SimCode.SimEqSystem eq;
  output SourceInfo info;
algorithm
  info := match eq
    case SimCode.SES_RESIDUAL(source=DAE.SOURCE(info=info)) then info;
    case SimCode.SES_SIMPLE_ASSIGN(source=DAE.SOURCE(info=info)) then info;
    case SimCode.SES_ARRAY_CALL_ASSIGN(source=DAE.SOURCE(info=info)) then info;
    case SimCode.SES_WHEN(source=DAE.SOURCE(info=info)) then info;
  end match;
end eqInfo;

public function eqIndex
  input SimCode.SimEqSystem eq;
  output Integer index;
algorithm
  index := match eq
    case SimCode.SES_RESIDUAL(index=index) then index;
    case SimCode.SES_SIMPLE_ASSIGN(index=index) then index;
    case SimCode.SES_ARRAY_CALL_ASSIGN(index=index) then index;
    case SimCode.SES_IFEQUATION(index=index) then index;
    case SimCode.SES_ALGORITHM(index=index) then index;
    case SimCode.SES_LINEAR(index=index) then index;
    case SimCode.SES_NONLINEAR(index=index) then index;
    case SimCode.SES_MIXED(index=index) then index;
    case SimCode.SES_WHEN(index=index) then index;
    else
      equation
        Error.addMessage(Error.INTERNAL_ERROR,{"SimCodeUtil.eqIndex failed"});
      then fail();
  end match;
end eqIndex;

function twodigit
  input Integer i;
  output String outS;
algorithm
  outS :=
  matchcontinue (i)
    local String s;
    case _
      equation
        (i < 10) = true;
        s = intString(i);
        s = stringAppend("0", s);
      then
        s;
    case _
      then
        intString(i);
  end matchcontinue;
end twodigit;




/**************************************/
/************* for index ***************/

protected function setVariableDerIndex "
Author bz 2008-06
This function investigates the system of equations finding an order for derivative variables.
It only selects variables that have an derivative order, order=0 (no derivative) will not be included.
"
  input BackendDAE.BackendDAE inDlow;
  input BackendDAE.EqSystems inEqSystems;
  output list<tuple<DAE.ComponentRef, Integer>> outOrder;
algorithm outOrder := matchcontinue(inDlow, inEqSystems)
  local
    list<tuple<DAE.ComponentRef, Integer>> variableIndex;
     list<tuple<DAE.ComponentRef, Integer>> variableIndex2;
      list<tuple<DAE.ComponentRef, Integer>> variableIndex3;
    BackendDAE.EqSystem syst;
    BackendDAE.EqSystems systs;
 case(_, {})
     then
     {};
 case(_, syst::systs)
    equation
      if Flags.isSet(Flags.FAILTRACE) then
        print(" set  variabale der index for eqsystem"+ "\n");
      end if;
      variableIndex =  setVariableDerIndex2(inDlow, syst);
      variableIndex2 = setVariableDerIndex(inDlow, systs);
      variableIndex3 = listAppend(variableIndex, variableIndex2);
    then variableIndex3;
  else
    equation
      print(" Failure in setVariableDerIndex \n");
    then fail();
 end matchcontinue;
end setVariableDerIndex;


protected function setVariableDerIndex2 "
Author bz 2008-06
This function investigates the system of equations finding an order for derivative variables.
It only selects variables that have an derivative order, order=0 (no derivative) will not be included.
"
  input BackendDAE.BackendDAE inDlow;
  input BackendDAE.EqSystem syst;
  output list<tuple<DAE.ComponentRef, Integer>> outOrder;
algorithm outOrder := matchcontinue(inDlow, syst)
  local
    BackendDAE.Variables dovars;
    BackendDAE.EquationArray deqns;
    list<BackendDAE.Equation> eqns;
    list<BackendDAE.Var> vars;
    list<DAE.Exp> derExps;
    list<tuple<DAE.ComponentRef, Integer>> variableIndex;
    list<list<DAE.ComponentRef>> firstOrderVars;
    list<DAE.ComponentRef> firstOrderVarsFiltered;
  case(_, _)
    equation
      if Flags.isSet(Flags.FAILTRACE) then
        print(" set variabale der index"+ "\n");
      end if;
      dovars = BackendVariable.daeVars(syst);
      deqns = BackendEquation.getEqnsFromEqSystem(syst);
      vars = BackendVariable.varList(dovars);
      eqns = BackendEquation.equationList(deqns);
      derExps = makeCallDerExp(vars);
      if Flags.isSet(Flags.FAILTRACE) then
        print(" possible der exp: " + stringDelimitList(List.map(derExps, ExpressionDump.printExpStr), ", ") + "\n");
      end if;
      eqns = flattenEqns(eqns, inDlow);
     // eq_str=dumpEqLst(eqns);
      // fcall(Flags.FAILTRACE, print, "filtered eq's " + eq_str + "\n");
      (variableIndex, firstOrderVars) = List.map2_2(derExps, locateDerAndSerachOtherSide, eqns, eqns);
      if Flags.isSet(Flags.FAILTRACE) then
        print("united variables \n");
      end if;
      firstOrderVarsFiltered = List.fold(firstOrderVars, List.union, {});
      if Flags.isSet(Flags.FAILTRACE) then
        print("list fold variables \n");
      end if;
      variableIndex = setFirstOrderInSecondOrderVarIndex(variableIndex, firstOrderVarsFiltered);
     // fcall(Flags.FAILTRACE, print, "Deriving Variable indexis:\n" + dumpVariableindex(variableIndex) + "\n");
     then
      variableIndex;
  case(_, _)
      equation
         print(" Failure in setVariableDerIndex2 \n");
         then fail();
 end matchcontinue;
end setVariableDerIndex2;




protected function flattenEqns "
This function flattens all equations
"
input list<BackendDAE.Equation> eqns;
input BackendDAE.BackendDAE dlow;
output list<BackendDAE.Equation> oeqns;
algorithm oeqns := matchcontinue(eqns, dlow)
  local
    BackendDAE.Equation eq;
    list<BackendDAE.Equation> rest, rec;
    String str;
  case({}, _) then {};
    case( (eq as BackendDAE.EQUATION()) ::rest , _)
    equation
      rec = flattenEqns(rest, dlow);
      rec = List.unionElt(eq, rec);
      then
        rec;
     case( (eq as BackendDAE.WHEN_EQUATION(whenEquation = BackendDAE.WHEN_EQ())) ::rest , _)
     equation
       str = BackendDump.equationString(eq);
       if Flags.isSet(Flags.FAILTRACE) then
         print("Found When eq " + str + "\n");
        end if;
       rec = flattenEqns(rest, dlow);
       // rec = List.unionElt(eq, rec);
      then
        rec;
     case( (eq as BackendDAE.ALGORITHM()) ::rest , _)
     equation
       // str = DAELow.equationStr(eq);
       rec = flattenEqns(rest, dlow);
       rec = List.unionElt(eq, rec);
      then
        rec;
     case( (eq as BackendDAE.ARRAY_EQUATION()) ::rest , _)
     equation
       // str = DAELow.equationStr(eq);
       rec = flattenEqns(rest, dlow);
       rec = List.unionElt(eq, rec);
      then
        rec;
     case( (eq as BackendDAE.COMPLEX_EQUATION()) ::rest , _)
     equation
       // str = DAELow.equationStr(eq);
       rec = flattenEqns(rest, dlow);
       rec = List.unionElt(eq, rec);
      then
        rec;
  case(_::_, _)
    equation
     // str = BackendDAE.equationStr(eq);
      true = Flags.isSet(Flags.FAILTRACE);
      print(" FAILURE IN flattenEqns possible unsupported equation...\n" /*+ str*/);
    then
      fail();
   end matchcontinue;
end flattenEqns;

protected function makeCallDerExp "
Author bz 2008-06
For all state-variables, generate an der(var) expression.
"
  input list<BackendDAE.Var> inVars;
  output list<DAE.Exp> outDerExps;
algorithm outDerExps := matchcontinue(inVars)
  local
    BackendDAE.Var v;
    list<BackendDAE.Var> vars;
    list<DAE.Exp> rec;
    DAE.ComponentRef cr;
  case({}) then {};
  case((BackendDAE.VAR(varKind = BackendDAE.STATE(), varName = cr))::vars)
    equation
      // true = DAELow.isStateVar(v);
      rec = makeCallDerExp(vars);
    then
      DAE.CALL(Absyn.IDENT("der"), {DAE.CREF(cr, DAE.T_REAL_DEFAULT)}, DAE.callAttrBuiltinReal)::rec;
  // case((v as DAELow.VAR(varKind = DAELow.DUMMY_STATE(), varName = cr))::vars)
   // equation
      // true = DAELow.isStateVar(v);
   // rec = makeCallDerExp(vars);
   // then
    // DAE.CALL(Absyn.IDENT("der"), {DAE.CREF(cr, DAE.T_UNKNOWN_DEFAULT)}, false, false, DAE.T_UNKNOWN_DEFAULT, DAE.NO_INLINE())::rec;
  case(_::vars)
    equation
      rec = makeCallDerExp(vars);
    then
      rec;
end matchcontinue;
end makeCallDerExp;

protected function locateDerAndSerachOtherSide "
Author bz 2008-06
helper function for setVariableDerIndex, locates the equation(/s) containing the current derivate.
From there search for the variable beeing derived, exclude 'current equation'
"
  input DAE.Exp derExp;
  input list<BackendDAE.Equation> inEqns;
  input list<BackendDAE.Equation> inEqnsOrg;
  output tuple<DAE.ComponentRef, Integer> out;
  output list<DAE.ComponentRef> sysOrdOneVars;
algorithm (out, sysOrdOneVars) := matchcontinue(derExp, inEqns, inEqnsOrg)
  local
    DAE.Exp e1, e2, deriveVar;
    list<BackendDAE.Equation> eqs, eqsOrg;
    BackendDAE.Equation eq;
    list<DAE.ComponentRef> crefs;
    DAE.ComponentRef cr;
    Integer rec, i1;
    tuple<DAE.ComponentRef, Integer> highestIndex;

  case( (DAE.CALL( expLst = {DAE.CREF(cr, _)})), {}, _) then ((cr, 0), {});
  case( (DAE.CALL( expLst = {deriveVar as DAE.CREF(cr, _)})), (eq as BackendDAE.EQUATION(exp=e1, scalar=e2))::eqs, _)
    equation
      true = Expression.expEqual(e1, derExp);
      eqsOrg = List.removeOnTrue(eq, valueEq, inEqnsOrg);
      if Flags.isSet(Flags.FAILTRACE) then
        print("\nFound equation containing " + ExpressionDump.printExpStr(derExp) + " Other side: " + ExpressionDump.printExpStr(e2) + ", extracted crefs: " + ExpressionDump.printExpStr(deriveVar) + "\n");
      end if;
      (rec, crefs) = locateDerAndSerachOtherSide2(DAE.CALL(Absyn.IDENT("der"), {e2}, DAE.callAttrBuiltinReal), eqsOrg);
      (highestIndex as (_, i1), _) = locateDerAndSerachOtherSide(derExp, eqs, eqsOrg);
      rec = rec+1;
      highestIndex = if i1>rec then highestIndex else (cr, rec-1);
      // highestIndex = (cr, 1);
    then
      (highestIndex, crefs);
  case( (DAE.CALL( expLst = {deriveVar as DAE.CREF(cr, _)})), (eq as BackendDAE.EQUATION(exp=e1, scalar=e2))::eqs, _)
    equation
      true = Expression.expEqual(e2, derExp);
      eqsOrg = List.removeOnTrue(eq, valueEq, inEqnsOrg);
      if Flags.isSet(Flags.FAILTRACE) then
        print("\nFound equation containing " + ExpressionDump.printExpStr(derExp) + " Other side: " + ExpressionDump.printExpStr(e1) + ", extracted crefs: " + ExpressionDump.printExpStr(deriveVar) + "\n");
      end if;
      (rec, crefs) = locateDerAndSerachOtherSide2(DAE.CALL(Absyn.IDENT("der"), {e1}, DAE.callAttrBuiltinReal), eqsOrg);
      (highestIndex as (_, i1), _) = locateDerAndSerachOtherSide(derExp, eqs, eqsOrg);
      rec = rec+1;
      highestIndex = if i1>rec then highestIndex else (cr, rec-1);
      // highestIndex = (cr, 1);
    then
      (highestIndex, crefs);
  case(_, (BackendDAE.EQUATION(exp=e1, scalar=e2))::eqs, _)
    equation
      false = Expression.expEqual(e1, derExp);
      false = Expression.expEqual(e2, derExp);
      (highestIndex, crefs) = locateDerAndSerachOtherSide(derExp, eqs, inEqnsOrg);
    then
      (highestIndex, crefs);
  case(_, (BackendDAE.ARRAY_EQUATION(left=e1, right=e2))::eqs, _)
    equation
      false = Expression.expEqual(e1, derExp);
      false = Expression.expEqual(e2, derExp);
      (highestIndex, crefs) = locateDerAndSerachOtherSide(derExp, eqs, inEqnsOrg);
    then
      (highestIndex, crefs);
  case(_, (BackendDAE.COMPLEX_EQUATION(left=e1, right=e2))::eqs, _)
    equation
      false = Expression.expEqual(e1, derExp);
      false = Expression.expEqual(e2, derExp);
      (highestIndex, crefs) = locateDerAndSerachOtherSide(derExp, eqs, inEqnsOrg);
    then
      (highestIndex, crefs);
  case(_, (BackendDAE.IF_EQUATION())::eqs, _)
    equation
      if Flags.isSet(Flags.FAILTRACE) then
        print("\nFound  if equation is not supported yet  searching for varibale index  \n");
      end if;
      (highestIndex, crefs) = locateDerAndSerachOtherSide(derExp, eqs, inEqnsOrg);
    then
      (highestIndex, crefs);
 case(_, (BackendDAE.ALGORITHM())::eqs, _)
    equation
      if Flags.isSet(Flags.FAILTRACE) then
        print("\nFound  algorithm is not supported yet  searching for varibale index  \n");
      end if;
      (highestIndex, crefs) = locateDerAndSerachOtherSide(derExp, eqs, inEqnsOrg);
    then
      (highestIndex, crefs);

end matchcontinue;
end locateDerAndSerachOtherSide;

protected function locateDerAndSerachOtherSide2 "
Author bz 2008-06
helper function for locateDerAndSerachOtherSide"
  input DAE.Exp inDer;
  input list<BackendDAE.Equation> inEqns;
  output Integer oi;
  output list<DAE.ComponentRef> firstOrderDers;
algorithm (oi, firstOrderDers) := matchcontinue(inDer, inEqns)
  case(DAE.CALL(expLst = {DAE.CREF(_, _)}), _)
    equation
      (oi, firstOrderDers) = locateDerAndSerachOtherSide22(inDer, inEqns);
    then
      (oi, firstOrderDers);
  case(_, _) then (0, {});
end matchcontinue;
  end locateDerAndSerachOtherSide2;

protected function locateDerAndSerachOtherSide22 "
Author bz 2008-06
recursivly search equations for der(..) expressions.
When found, return 1... this since we are only interested in second order system, at most.
If we do not find any more derivative, 0 is returned.
"
  input DAE.Exp inDer;
  input list<BackendDAE.Equation> inEqns;
  output Integer oi;
  output list<DAE.ComponentRef> firstOrderDers;
algorithm (oi, firstOrderDers) := matchcontinue(inDer, inEqns)
  local
    DAE.Exp e1, e2;
    DAE.ComponentRef cr;
    list<BackendDAE.Equation> rest;
  case(_, {}) then (0, {});
  case(_, (BackendDAE.EQUATION(exp=e1, scalar=e2)::_))
    equation
      true = Expression.expEqual(inDer, e1);
      {cr} = Expression.extractCrefsFromExp(e1);
      if Flags.isSet(Flags.FAILTRACE) then
        BackendDump.debugStrExpStrExpStrExpStr(" found derivative for ", inDer, " in equation ", e1, " = ", e2, "\n");
      end if;
    then
      (1, {cr});
  case(_, (BackendDAE.EQUATION(exp=e1, scalar=e2)::_))
    equation
      true = Expression.expEqual(inDer, e2);
      {cr} = Expression.extractCrefsFromExp(e2);
      if Flags.isSet(Flags.FAILTRACE) then
        BackendDump.debugStrExpStrExpStrExpStr(" found derivative for ", inDer, " in equation ", e1, " = ", e2, "\n");
      end if;
    then
      (1, {cr});
  case(_, (BackendDAE.EQUATION(exp=e1, scalar=e2)::rest))
    equation
      if Flags.isSet(Flags.FAILTRACE) then
        BackendDump.debugExpStrExpStrExpStr(inDer, " NOT contained in ", e1, " = ", e2, "\n");
      end if;
      (oi, firstOrderDers) = locateDerAndSerachOtherSide22(inDer, rest);
    then
      (oi, firstOrderDers);
end matchcontinue;
end locateDerAndSerachOtherSide22;

protected function setFirstOrderInSecondOrderVarIndex "
Author bz 2008-06
"
  input list<tuple<DAE.ComponentRef, Integer>> inRefs;
  input list<DAE.ComponentRef> firstOrderInSec;
  output list<tuple<DAE.ComponentRef, Integer>> outRefs;
algorithm (outRefs) := matchcontinue(inRefs, firstOrderInSec)
  local
    list<tuple<DAE.ComponentRef, Integer>> rest;
    Integer idx;
    DAE.ComponentRef cr;
    list<Boolean> bl;

  case({}, _) then {};
  case((cr, _)::rest, _)
    equation
      bl = List.map1(firstOrderInSec, ComponentReference.crefEqual, cr);
      true = Util.boolOrList(bl);
      rest = setFirstOrderInSecondOrderVarIndex(rest, firstOrderInSec);
    then
      (cr, 2)::rest;
  case((cr, 1)::rest, _)
    equation
      rest = setFirstOrderInSecondOrderVarIndex(rest, firstOrderInSec);
    then
      (cr, 1)::rest;
  case((cr, idx)::rest, _)
    equation
      rest = setFirstOrderInSecondOrderVarIndex(rest, firstOrderInSec);
    then
      (cr, idx)::rest;
end matchcontinue;
end setFirstOrderInSecondOrderVarIndex;

/********* for dimension *******/

protected function calculateVariableDimensions "
Calcuates the dimesion of the statevaribale with order 0, 1, 2
"
   input list<tuple<DAE.ComponentRef, Integer>> in_vars;
   output Integer OutInteger1; // number of ordinary differential equations of 1st order
   output Integer OutInteger2; // number of ordinary differential equations of 2st order

algorithm (OutInteger1, OutInteger2) := matchcontinue(in_vars)
  local
    list<tuple<DAE.ComponentRef, Integer>> rest;
    DAE.ComponentRef cr;
    Integer nvar1, nvar2;
  case({}) then (0, 0);
  case((_, 0)::rest)
    equation
     (nvar1, nvar2) = calculateVariableDimensions(rest);
    then
      (nvar1+1, nvar2);
  case((_, _)::rest)
    equation
      (nvar1, nvar2) = calculateVariableDimensions(rest);
    then
      (nvar1, nvar2+1);
end matchcontinue;
end calculateVariableDimensions;

/********************/
protected function dimensions

input BackendDAE.BackendDAE dae_low;
output Integer OutInteger1; // number of ordinary differential equations of 1st order
output Integer OutInteger2; // number of ordinary differential equations of 2st order
algorithm (OutInteger1, OutInteger2):= matchcontinue(dae_low)
  local
    Integer nvar1, nvar2;
    list<tuple<DAE.ComponentRef, Integer>> ordered_states;
    BackendDAE.EqSystems eqsystems;
  case(BackendDAE.DAE(eqs=eqsystems))
    equation
       ordered_states=setVariableDerIndex(dae_low, eqsystems);
      (nvar1, nvar2)=calculateVariableDimensions(ordered_states);
      then
        (nvar1, nvar2);
  case(_)
    equation print(" failure in dimensions  \n"); then fail();
end matchcontinue;
end dimensions;

/******************/
/******************/

public function varIndex
  input SimCodeVar.SimVar var;
  output Integer index;
algorithm
  SimCodeVar.SIMVAR(index=index) := var;
end varIndex;

public function varName
  input SimCodeVar.SimVar var;
  output DAE.ComponentRef name;
algorithm
  SimCodeVar.SIMVAR(name=name) := var;
end varName;

public function countDynamicExternalFunctions
  input list<SimCode.Function> inFncLst;
  output Integer outDynLoadFuncs;
algorithm
  outDynLoadFuncs:= matchcontinue(inFncLst)
  local
     list<SimCode.Function> rest;
     SimCode.Function fn;
     Integer i;
  case({})
     then
       0;
  case(SimCode.EXTERNAL_FUNCTION(dynamicLoad=true)::rest)
     equation
      i = countDynamicExternalFunctions(rest);
    then
      intAdd(i, 1);
  case(_::rest)
    equation
      i = countDynamicExternalFunctions(rest);
    then
      i;
end matchcontinue;
end countDynamicExternalFunctions;

protected function getFilesFromSimVar
  input SimCodeVar.SimVar inSimVar;
  input SimCode.Files inFiles;
  output SimCodeVar.SimVar outSimVar;
  output SimCode.Files outFiles;
algorithm
  (outSimVar, outFiles) := match(inSimVar, inFiles)
    local
      SimCode.Files files;
      DAE.ElementSource source;

    case (SimCodeVar.SIMVAR(source = source), files)
      equation
        files = getFilesFromDAEElementSource(source, files);
      then
        (inSimVar, files);
  end match;
end getFilesFromSimVar;

protected function getFilesFromSimVars
  input SimCodeVar.SimVars inSimVars;
  input SimCode.Files inFiles;
  output SimCode.Files outFiles;
algorithm
  outFiles := match(inSimVars, inFiles)
    local
      SimCode.Files files;
      list<SimCodeVar.SimVar> stateVars, derivativeVars, algVars, discreteAlgVars, intAlgVars, boolAlgVars, inputVars, outputVars, aliasVars, intAliasVars,
                   boolAliasVars, paramVars, intParamVars, boolParamVars, stringAlgVars, stringParamVars, stringAliasVars,
                   extObjVars, constVars, intConstVars, boolConstVars, stringConstVars, jacobianVars, realOptimizeConstraintsVars, realOptimizeFinalConstraintsVars;

    case (SimCodeVar.SIMVARS(stateVars, derivativeVars, algVars, discreteAlgVars, intAlgVars, boolAlgVars, inputVars, outputVars, aliasVars, intAliasVars, boolAliasVars,
                  paramVars, intParamVars, boolParamVars, stringAlgVars, stringParamVars, stringAliasVars, extObjVars, constVars, intConstVars, boolConstVars, stringConstVars, jacobianVars, realOptimizeConstraintsVars, realOptimizeFinalConstraintsVars),
          files)
      equation
        (_, files) = List.mapFoldList(
                       {stateVars, derivativeVars, algVars, discreteAlgVars, intAlgVars, boolAlgVars, inputVars, outputVars, aliasVars, intAliasVars, boolAliasVars,
                        paramVars, intParamVars, boolParamVars, stringAlgVars, stringParamVars, stringAliasVars, extObjVars, constVars, intConstVars, boolConstVars, stringConstVars, jacobianVars, realOptimizeConstraintsVars, realOptimizeFinalConstraintsVars},
                       getFilesFromSimVar, files);
      then
        files;
  end match;
end getFilesFromSimVars;

protected function getFilesFromFunctions
  input list<SimCode.Function> functions;
  input SimCode.Files inFiles;
  output SimCode.Files outFiles;
algorithm
  outFiles := match(functions, inFiles)
    local
      SimCode.Files files;
      list<SimCode.Function> rest;
      SourceInfo info;

    // handle empty
    case ({}, files) then files;

    // handle FUNCTION
    case (SimCode.FUNCTION(info = info)::rest, files)
      equation
        files = getFilesFromAbsynInfo(info, files);
        files = getFilesFromFunctions(rest, files);
      then
        files;

    // handle EXTERNAL_FUNCTION
    case (SimCode.EXTERNAL_FUNCTION(info = info)::rest, files)
      equation
        files = getFilesFromAbsynInfo(info, files);
        files = getFilesFromFunctions(rest, files);
      then
        files;

    // handle RECORD_CONSTRUCTOR
    case (SimCode.RECORD_CONSTRUCTOR(info = info)::rest, files)
      equation
        files = getFilesFromAbsynInfo(info, files);
        files = getFilesFromFunctions(rest, files);
      then
        files;
  end match;
end getFilesFromFunctions;

protected function getFilesFromSimEqSystemOpt
  input Option<SimCode.SimEqSystem> inSimEqSystemOpt;
  input SimCode.Files inFiles;
  output SimCode.Files outFiles;
algorithm
  outFiles := match(inSimEqSystemOpt, inFiles)
    local
      SimCode.Files files;
      SimCode.SimEqSystem sys;

    case (NONE(), files) then files;
    case (SOME(sys), files)
      equation
        (_, files) = getFilesFromSimEqSystem(sys, files);
      then
        files;
  end match;
end getFilesFromSimEqSystemOpt;

protected function getFilesFromSimEqSystem
  input SimCode.SimEqSystem inSimEqSystem;
  input SimCode.Files inFiles;
  output SimCode.SimEqSystem outSimEqSystem;
  output SimCode.Files outFiles;
algorithm
  (outSimEqSystem, outFiles) := match(inSimEqSystem, inFiles)
    local
      SimCode.Files files;
      DAE.ElementSource source;
      list<DAE.Statement> statements;
      list<SimCodeVar.SimVar> vars;
      list<tuple<Integer, Integer, SimCode.SimEqSystem>> simJac;
      list<SimCode.SimEqSystem> systems;
      SimCode.SimEqSystem system;
      Option<SimCode.SimEqSystem> systemOpt;

    case (SimCode.SES_RESIDUAL(source = source), files)
      equation
        files = getFilesFromDAEElementSource(source, files);
      then
        (inSimEqSystem, files);

    case (SimCode.SES_SIMPLE_ASSIGN(source = source), files)
      equation
        files = getFilesFromDAEElementSource(source, files);
      then
        (inSimEqSystem, files);

    case (SimCode.SES_ARRAY_CALL_ASSIGN(source = source), files)
      equation
        files = getFilesFromDAEElementSource(source, files);
      then
        (inSimEqSystem, files);

    case (SimCode.SES_ALGORITHM(statements=statements), files)
      equation
        files = getFilesFromStatements(statements, files);
      then
        (inSimEqSystem, files);

    case (SimCode.SES_LINEAR(vars = vars, simJac = simJac), files)
      equation
        (_, files) = List.mapFold(vars, getFilesFromSimVar, files);
        systems = List.map(simJac, Util.tuple33);
        files = getFilesFromSimEqSystems({systems}, files);
      then
        (inSimEqSystem, files);

    case (SimCode.SES_NONLINEAR(eqs = systems), files)
      equation
        files = getFilesFromSimEqSystems({systems}, files);
      then
        (inSimEqSystem, files);

    case (SimCode.SES_MIXED(cont = system, discVars = vars, discEqs = systems), files)
      equation
        (_, files) = List.mapFold(vars, getFilesFromSimVar, files);
        files = getFilesFromSimEqSystems({system::systems}, files);
      then
        (inSimEqSystem, files);

    case (SimCode.SES_WHEN(source = source, elseWhen = systemOpt), files)
      equation
        files = getFilesFromDAEElementSource(source, files);
        files = getFilesFromSimEqSystemOpt(systemOpt, files);
      then
        (inSimEqSystem, files);

  end match;
end getFilesFromSimEqSystem;

protected function getFilesFromSimEqSystems
  input list<list<SimCode.SimEqSystem>> inSimEqSystems;
  input SimCode.Files inFiles;
  output SimCode.Files outFiles;
algorithm
  (_, outFiles) := List.mapFoldList(inSimEqSystems, getFilesFromSimEqSystem, inFiles);
end getFilesFromSimEqSystems;

protected function getFilesFromStatementsElse
  input DAE.Else inElse;
  input SimCode.Files inFiles;
  output SimCode.Files outFiles;
algorithm
  outFiles := match(inElse, inFiles)
    local
      SimCode.Files files;
      list<DAE.Statement> rest, stmts;
      DAE.Else elsePart;

    case (DAE.NOELSE(), files) then files;

    case (DAE.ELSEIF(statementLst = stmts, else_ = elsePart), files)
      equation
        files = getFilesFromStatements(stmts, files);
        files = getFilesFromStatementsElse(elsePart, files);
      then
        files;

    case (DAE.ELSE(statementLst = stmts), files)
      equation
        files = getFilesFromStatements(stmts, files);
      then
        files;
  end match;
end getFilesFromStatementsElse;

protected function getFilesFromStatementsElseWhen
  input Option<DAE.Statement> inStatementOpt;
  input SimCode.Files inFiles;
  output SimCode.Files outFiles;
algorithm
  outFiles := match(inStatementOpt, inFiles)
    local
      SimCode.Files files;
      DAE.Statement stmt;

    case (NONE(), files) then files;
    case (SOME(stmt), files) then getFilesFromStatements({stmt}, files);
  end match;
end getFilesFromStatementsElseWhen;

protected function getFilesFromStatements
  input list<DAE.Statement> inStatements;
  input SimCode.Files inFiles;
  output SimCode.Files outFiles;
algorithm
  outFiles := match(inStatements, inFiles)
    local
      SimCode.Files files;
      DAE.ElementSource source;
      list<DAE.Statement> rest, stmts;
      DAE.Else elsePart;
      Option<DAE.Statement> elseWhen;

    // handle empty
    case ({}, files) then files;

    case (DAE.STMT_ASSIGN(source = source)::rest, files)
      equation
        files = getFilesFromDAEElementSource(source, files);
        files = getFilesFromStatements(rest, files);
      then
        files;

    case (DAE.STMT_TUPLE_ASSIGN(source = source)::rest, files)
      equation
        files = getFilesFromDAEElementSource(source, files);
        files = getFilesFromStatements(rest, files);
      then
        files;

    case (DAE.STMT_ASSIGN_ARR(source = source)::rest, files)
      equation
        files = getFilesFromDAEElementSource(source, files);
        files = getFilesFromStatements(rest, files);
      then
        files;

    case (DAE.STMT_IF(source = source, statementLst = stmts, else_ = elsePart)::rest, files)
      equation
        files = getFilesFromDAEElementSource(source, files);
        files = getFilesFromStatements(stmts, files);
        files = getFilesFromStatementsElse(elsePart, files);
        files = getFilesFromStatements(rest, files);
      then
        files;

    case (DAE.STMT_FOR(source = source, statementLst = stmts)::rest, files)
      equation
        files = getFilesFromDAEElementSource(source, files);
        files = getFilesFromStatements(stmts, files);
        files = getFilesFromStatements(rest, files);
      then
        files;

    case (DAE.STMT_PARFOR(source = source, statementLst = stmts)::rest, files)
      equation
        files = getFilesFromDAEElementSource(source, files);
        files = getFilesFromStatements(stmts, files);
        files = getFilesFromStatements(rest, files);
      then
        files;

    case (DAE.STMT_WHILE(source = source, statementLst = stmts)::rest, files)
      equation
        files = getFilesFromDAEElementSource(source, files);
        files = getFilesFromStatements(stmts, files);
        files = getFilesFromStatements(rest, files);
      then
        files;

    case (DAE.STMT_WHEN(source = source, statementLst = stmts, elseWhen = elseWhen)::rest, files)
      equation
        files = getFilesFromDAEElementSource(source, files);
        files = getFilesFromStatements(stmts, files);
        files = getFilesFromStatementsElseWhen(elseWhen, files);
        files = getFilesFromStatements(rest, files);
      then
        files;

    case (DAE.STMT_ASSERT(source = source)::rest, files)
      equation
        files = getFilesFromDAEElementSource(source, files);
        files = getFilesFromStatements(rest, files);
      then
        files;

    case (DAE.STMT_TERMINATE(source = source)::rest, files)
      equation
        files = getFilesFromDAEElementSource(source, files);
        files = getFilesFromStatements(rest, files);
      then
        files;

    case (DAE.STMT_REINIT(source = source)::rest, files)
      equation
        files = getFilesFromDAEElementSource(source, files);
        files = getFilesFromStatements(rest, files);
      then
        files;

    case (DAE.STMT_NORETCALL(source = source)::rest, files)
      equation
        files = getFilesFromDAEElementSource(source, files);
        files = getFilesFromStatements(rest, files);
      then
        files;

    case (DAE.STMT_RETURN(source = source)::rest, files)
      equation
        files = getFilesFromDAEElementSource(source, files);
        files = getFilesFromStatements(rest, files);
      then
        files;

    case (DAE.STMT_BREAK(source = source)::rest, files)
      equation
        files = getFilesFromDAEElementSource(source, files);
        files = getFilesFromStatements(rest, files);
      then
        files;

    case (DAE.STMT_FAILURE(source = source, body = stmts)::rest, files)
      equation
        files = getFilesFromDAEElementSource(source, files);
        files = getFilesFromStatements(stmts, files);
        files = getFilesFromStatements(rest, files);
      then
        files;

  end match;
end getFilesFromStatements;

protected function getFilesFromWhenClausesReinits
  input list<BackendDAE.WhenOperator> inWhenOperators;
  input SimCode.Files inFiles;
  output SimCode.Files outFiles;
algorithm
  outFiles := match(inWhenOperators, inFiles)
    local
      SimCode.Files files;
      DAE.ElementSource source;
      list<BackendDAE.WhenOperator> rest;

    // handle empty
    case ({}, files) then files;

    case (BackendDAE.REINIT(source = source)::rest, files)
      equation
        files = getFilesFromDAEElementSource(source, files);
        files = getFilesFromWhenClausesReinits(rest, files);
      then
        files;

  end match;
end getFilesFromWhenClausesReinits;

protected function getFilesFromWhenClauses
  input list<SimCode.SimWhenClause> inSimWhenClauses;
  input SimCode.Files inFiles;
  output SimCode.Files outFiles;
algorithm
  outFiles := match(inSimWhenClauses, inFiles)
    local
      SimCode.Files files;
      list<SimCode.SimWhenClause> rest;
      list<BackendDAE.WhenOperator> reinits;

    // handle empty
    case ({}, files) then files;

    case (SimCode.SIM_WHEN_CLAUSE(reinits = reinits)::rest, files)
      equation
        files = getFilesFromWhenClausesReinits(reinits, files);
        files = getFilesFromWhenClauses(rest, files);
      then
        files;

  end match;
end getFilesFromWhenClauses;

protected function getFilesFromExtObjInfo
  input SimCode.ExtObjInfo inExtObjInfo;
  input SimCode.Files inFiles;
  output SimCode.Files outFiles;
algorithm
  outFiles := match(inExtObjInfo, inFiles)
    local
      SimCode.Files files;
      list<SimCodeVar.SimVar> vars;

    case (SimCode.EXTOBJINFO(vars = vars), files)
      equation
        (_, files) = List.mapFold(vars, getFilesFromSimVar, files);
      then
        files;

  end match;
end getFilesFromExtObjInfo;

protected function getFilesFromJacobianMatrixes
  input list<SimCode.JacobianMatrix> inJacobianMatrixes;
  input SimCode.Files inFiles;
  output SimCode.Files outFiles;
algorithm
  outFiles := match(inJacobianMatrixes, inFiles)
    local
      SimCode.Files files;
      list<SimCode.JacobianMatrix> rest;
      list<SimCode.JacobianColumn> onemat;
      list<SimCode.SimEqSystem> systems;
      list<SimCodeVar.SimVar> vars;

    // handle empty
    case ({}, files) then files;

    // handle rest
    case ((onemat, _, _, _, _, _, _)::rest, files)
      equation
        files = getFilesFromJacobianMatrix(onemat, files);
        files = getFilesFromJacobianMatrixes(rest, files);
      then
        files;

  end match;
end getFilesFromJacobianMatrixes;

protected function getFilesFromJacobianMatrix
  input list<SimCode.JacobianColumn> inJacobianMatrixes;
  input SimCode.Files inFiles;
  output SimCode.Files outFiles;
algorithm
  outFiles := match(inJacobianMatrixes, inFiles)
    local
      SimCode.Files files;
      list<SimCode.JacobianColumn> rest;
      list<SimCode.SimEqSystem> systems;
      list<SimCodeVar.SimVar> vars;

    // handle empty
    case ({}, files) then files;

    // handle rest
    case ((systems, vars, _)::rest, files)
      equation
        files = getFilesFromSimEqSystems({systems}, files);
        (_, files) = List.mapFold(vars, getFilesFromSimVar, files);
        files = getFilesFromJacobianMatrix(rest, files);
      then
        files;

  end match;
end getFilesFromJacobianMatrix;

protected function collectAllFiles
  input SimCode.SimCode inSimCode;
  output SimCode.SimCode outSimCode;
algorithm
  outSimCode := matchcontinue(inSimCode)
    local
      SimCode.ModelInfo modelInfo;
      list<DAE.Exp> literals "shared literals";
      list<SimCode.RecordDeclaration> recordDecls;
      list<String> externalFunctionIncludes;
      list<list<SimCode.SimEqSystem>> eqsTmp;
      list<list<SimCode.SimEqSystem>> odeEquations, algebraicEquations;
      list<SimCode.SimEqSystem> allEquations, residualEquations, startValueEquations, nominalValueEquations, minValueEquations, maxValueEquations, parameterEquations, removedEquations, algorithmAndEquationAsserts, jacobianEquations, equationsForZeroCrossings;
      list<SimCode.StateSet> stateSets;
      Boolean useSymbolicInitialization, useHomotopy;
      list<SimCode.SimEqSystem> initialEquations, removedInitialEquations;
      list<DAE.Constraint> constraints;
      list<DAE.ClassAttributes> classAttributes;
      list<BackendDAE.ZeroCrossing> zeroCrossings, relations;
      list<SimCode.SimWhenClause> whenClauses;
      list<DAE.ComponentRef> discreteModelVars;
      SimCode.ExtObjInfo extObjInfo;
      SimCode.MakefileParams makefileParams;
      SimCode.DelayedExpression delayedExps;
      list<SimCode.JacobianMatrix> jacobianMatrixes;
      list<String> labels;
      Option<SimCode.SimulationSettings> simulationSettingsOpt;
      list<BackendDAE.TimeEvent> timeEvents;
      String fileNamePrefix;
      SimCode.HashTableCrefToSimVar crefToSimVarHT;
      Absyn.Path name;
      String description,directory;
      SimCode.VarInfo varInfo;
      SimCodeVar.SimVars vars;
      list<SimCode.Function> functions;
      SimCode.Files files "all the files from SourceInfo and DAE.ELementSource";
      Option<HpcOmSimCode.Schedule> hpcOmSchedule;
      Option<SimCode.BackendMapping> backendMapping;
      Option<HpcOmSimCode.MemoryMap> hpcOmMemory;
      list<SimCode.SimEqSystem> equationsForConditions;
    case _
      equation
        true = Config.acceptMetaModelicaGrammar();
      then inSimCode;

    case SimCode.SIMCODE(modelInfo, literals, recordDecls, externalFunctionIncludes, allEquations, odeEquations, algebraicEquations, residualEquations, useSymbolicInitialization, useHomotopy, initialEquations, removedInitialEquations, startValueEquations, nominalValueEquations, minValueEquations, maxValueEquations,
                 parameterEquations, removedEquations, algorithmAndEquationAsserts, equationsForZeroCrossings, jacobianEquations, stateSets, constraints, classAttributes, zeroCrossings, relations, timeEvents, whenClauses,
                 discreteModelVars, extObjInfo, makefileParams, delayedExps, jacobianMatrixes, simulationSettingsOpt, fileNamePrefix, hpcOmSchedule, hpcOmMemory, equationsForConditions, crefToSimVarHT, backendMapping)
      equation
        SimCode.MODELINFO(name, description, directory, varInfo, vars, functions, labels) = modelInfo;
        files = {};
        files = getFilesFromSimVars(vars, files);
        files = getFilesFromFunctions(functions, files);
        files = getFilesFromSimEqSystems(allEquations::residualEquations::
                                         startValueEquations::nominalValueEquations::minValueEquations::maxValueEquations::parameterEquations::removedEquations::algorithmAndEquationAsserts::odeEquations, files);
        files = getFilesFromSimEqSystems(algebraicEquations, files);
        files = getFilesFromWhenClauses(whenClauses, files);
        files = getFilesFromExtObjInfo(extObjInfo, files);
        files = getFilesFromJacobianMatrixes(jacobianMatrixes, files);
        files = List.sort(files, greaterFileInfo);
        modelInfo = SimCode.MODELINFO(name, description, directory, varInfo, vars, functions, labels);
      then
        SimCode.SIMCODE(modelInfo, literals, recordDecls, externalFunctionIncludes, allEquations, odeEquations, algebraicEquations, residualEquations, useSymbolicInitialization, useHomotopy, initialEquations, removedInitialEquations, startValueEquations, nominalValueEquations, minValueEquations, maxValueEquations,
                  parameterEquations, removedEquations, algorithmAndEquationAsserts, equationsForZeroCrossings, jacobianEquations, stateSets, constraints, classAttributes, zeroCrossings, relations, timeEvents, whenClauses,
                  discreteModelVars, extObjInfo, makefileParams, delayedExps, jacobianMatrixes, simulationSettingsOpt, fileNamePrefix, hpcOmSchedule, hpcOmMemory, equationsForConditions, crefToSimVarHT,backendMapping);

    case _
      equation
        Error.addMessage(Error.INTERNAL_ERROR, {"function collectAllFiles failed to collect files from SimCode!"});
      then
        inSimCode;
  end matchcontinue;
end collectAllFiles;

protected function getFilesFromDAEElementSource
  input DAE.ElementSource inSource;
  input SimCode.Files inFiles;
  output SimCode.Files outFiles;
algorithm
  outFiles := match(inSource, inFiles)
    local
      SimCode.Files files;
      SourceInfo info;

    case (DAE.SOURCE(info = info), files)
      equation
        files = getFilesFromAbsynInfo(info, files);
      then
        files;
  end match;
end getFilesFromDAEElementSource;

protected function getFilesFromAbsynInfo
  input SourceInfo inInfo;
  input SimCode.Files inFiles;
  output SimCode.Files outFiles;
algorithm
  outFiles := match(inInfo, inFiles)
    local
      SimCode.Files files;
      String f;
      Boolean ro;
      SimCode.FileInfo fi;

    case (SOURCEINFO(fileName = f, isReadOnly = ro), files)
      equation
        fi = SimCode.FILEINFO(f, ro);
        // add it only if is not already there!
        files = List.consOnTrue(not listMember(fi, files), fi, files);
      then
        files;
  end match;
end getFilesFromAbsynInfo;

protected function equalFileInfo
"compare to SimCode.FileInfo and return true if the filenames are equal, isReadOnly is ignored here"
  input SimCode.FileInfo inFileInfo1;
  input SimCode.FileInfo inFileInfo2;
  output Boolean isMatch;
protected
  String f1, f2;
algorithm
  SimCode.FILEINFO(f1, _) := inFileInfo1;
  SimCode.FILEINFO(f2, _) := inFileInfo2;
  isMatch := stringEq(f1, f2);
end equalFileInfo;

protected function greaterFileInfo
"compare to SimCode.FileInfo and returns true if the fileName1 is greater than fileName2, isReadOnly is ignored here"
  input SimCode.FileInfo inFileInfo1;
  input SimCode.FileInfo inFileInfo2;
  output Boolean isGreater;
protected
  String f1, f2;
  Integer compare;
algorithm
  SimCode.FILEINFO(f1, _) := inFileInfo1;
  SimCode.FILEINFO(f2, _) := inFileInfo2;
  compare := stringCompare(f1, f2);
  isGreater := intGt(compare, 0);
end greaterFileInfo;

protected function getFileIndexFromFiles
"fetch the index in the list of files"
  input String file;
  input SimCode.Files files;
  output Integer index;
algorithm
  index := List.positionOnTrue(SimCode.FILEINFO(file, false), files, equalFileInfo)-1 "shift to zero-based index";
end getFileIndexFromFiles;

public function fileName2fileIndex
"Used by templates to find a fileIndex for given fileName"
  input String inFileName;
  input SimCode.Files inFiles;
  output Integer outFileIndex;
algorithm
  outFileIndex := matchcontinue(inFileName, inFiles)
    local
      String errstr;
      String file;
      SimCode.Files files;
      Integer index;

    case (file, files)
      equation
        index = getFileIndexFromFiles(file, files);
      then
        index;

    case (_, _)
      equation
        // errstr = "Template did not find the file: "+ file + " in the SimCode.modelInfo.files.";
        // Error.addMessage(Error.INTERNAL_ERROR, {errstr});
      then
        -1;
  end matchcontinue;
end fileName2fileIndex;

protected function makeEqualLengthLists
  "Greedy algorithm for scheduling. Very simple:
  Calculate the weight of each eq.system, sort these s.t.
  the most expensive system is treated first. Add
  this eq.system to the block with the least cost at the moment.
  "
  input list<list<SimCode.SimEqSystem>> inLst;
  input Integer i;
  output list<list<SimCode.SimEqSystem>> olst;
algorithm
  olst := matchcontinue (inLst, i)
    local
      list<SimCode.SimEqSystem> l;
      PriorityQueue.T q;
      list<tuple<Integer, list<SimCode.SimEqSystem>>> prios;
      list<list<SimCode.SimEqSystem>> lst;
      String eq_str;

    case (lst, _)
      equation
        false = Flags.isSet(Flags.PTHREADS);
        l = List.flatten(lst);
      then l::{};
    case (lst, 0) then lst;
    case (lst, 1)
      equation
        l = List.flatten(lst);
        /* eq_str = Tpl.tplString2(SimCodeDump.dumpEqsSys, l, false);
        print(eq_str); */
      then l::{};
    case (lst, _)
      equation
        q = List.fold(List.fill((0, {}), i), PriorityQueue.insert, PriorityQueue.empty);
        prios = List.map(lst, calcPriority);
        q = List.fold(prios, makeEqualLengthLists2, q);
        lst = List.map(PriorityQueue.elements(q), Util.tuple22);
      then lst;
  end matchcontinue;
end makeEqualLengthLists;

protected function makeEqualLengthLists2
  input tuple<Integer, list<SimCode.SimEqSystem>> elt;
  input PriorityQueue.T iq;
  output PriorityQueue.T oq;
algorithm
  oq := match (elt, iq)
    local
      list<SimCode.SimEqSystem> l1, l2;
      Integer i1, i2;
      PriorityQueue.T q;

    case ((i1, l1), q)
      equation
        // print("priorities before: " + stringDelimitList(List.map(List.map(PriorityQueue.elements(q), Util.tuple21), intString), ", ") + "\n");
        (q, (i2, l2)) = PriorityQueue.deleteAndReturnMin(q);
        // print("priorities (popped): " + stringDelimitList(List.map(List.map(PriorityQueue.elements(q), Util.tuple21), intString), ", ") + "\n");
        q = PriorityQueue.insert((i1+i2, listAppend(l2, l1)), q);
        // print("priorities after (i1=" + intString(i1) + "): " + stringDelimitList(List.map(List.map(PriorityQueue.elements(q), Util.tuple21), intString), ", ") + "\n");
      then q;
  end match;
end makeEqualLengthLists2;

protected function calcPriority
  input list<SimCode.SimEqSystem> eqs;
  output tuple<Integer, list<SimCode.SimEqSystem>> prio;
protected
  Integer i;
algorithm
  (_, i) := traverseExpsEqSystems(eqs, Expression.complexityTraverse, 1 /* Each system has cost 1 even if it's as simple as der(x)=1.0 */, {});
  prio := (i, eqs);
end calcPriority;

protected function traveseSimVars
  input SimCodeVar.SimVars inSimVars;
  input Func func;
  input tpl iTpl;
  output SimCodeVar.SimVars outSimVars;
  output tpl oTpl;
  replaceable type tpl subtypeof Any;
  partial function Func
    input tuple<SimCodeVar.SimVar, tpl> tpl;
    output tuple<SimCodeVar.SimVar, tpl> otpl;
  end Func;
algorithm
  (outSimVars, oTpl) := match(inSimVars, func, iTpl)
    local
     list<SimCodeVar.SimVar> stateVars, derivativeVars, algVars, discreteAlgVars, intAlgVars, boolAlgVars, inputVars, outputVars, aliasVars, intAliasVars,
                   boolAliasVars, paramVars, intParamVars, boolParamVars, stringAlgVars, stringParamVars, stringAliasVars,
                   extObjVars, constVars, intConstVars, boolConstVars, stringConstVars, jacobianVars, realOptimizeConstraintsVars, realOptimizeFinalConstraintsVars;
     tpl intpl;

    case (SimCodeVar.SIMVARS(stateVars, derivativeVars, algVars, discreteAlgVars, intAlgVars, boolAlgVars, inputVars, outputVars, aliasVars, intAliasVars, boolAliasVars,
                  paramVars, intParamVars, boolParamVars, stringAlgVars, stringParamVars, stringAliasVars, extObjVars, constVars, intConstVars, boolConstVars, stringConstVars, jacobianVars, realOptimizeConstraintsVars, realOptimizeFinalConstraintsVars), _, intpl)
         equation
           (stateVars, intpl) = List.mapFoldTuple(stateVars, func, intpl);
           (derivativeVars, intpl) = List.mapFoldTuple(derivativeVars, func, intpl);
           (algVars, intpl) = List.mapFoldTuple(algVars, func, intpl);
           (discreteAlgVars, intpl) = List.mapFoldTuple(discreteAlgVars, func, intpl);
           (intAlgVars, intpl) = List.mapFoldTuple(intAlgVars, func, intpl);
           (boolAlgVars, intpl) = List.mapFoldTuple(boolAlgVars, func, intpl);
           (outputVars, intpl) = List.mapFoldTuple(outputVars, func, intpl);
           (aliasVars, intpl) = List.mapFoldTuple(aliasVars, func, intpl);
           (intAliasVars, intpl) = List.mapFoldTuple(intAliasVars, func, intpl);
           (boolAliasVars, intpl) = List.mapFoldTuple(boolAliasVars, func, intpl);
           (paramVars, intpl) = List.mapFoldTuple(intParamVars, func, intpl);
           (intParamVars, intpl) = List.mapFoldTuple(paramVars, func, intpl);
           (boolParamVars, intpl) = List.mapFoldTuple(boolParamVars, func, intpl);
           (stringAlgVars, intpl) = List.mapFoldTuple(stateVars, func, intpl);
           (stateVars, intpl) = List.mapFoldTuple(stringAlgVars, func, intpl);
           (stringParamVars, intpl) = List.mapFoldTuple(stringParamVars, func, intpl);
           (stringAliasVars, intpl) = List.mapFoldTuple(stringAliasVars, func, intpl);
           (extObjVars, intpl) = List.mapFoldTuple(extObjVars, func, intpl);
           (intConstVars, intpl) = List.mapFoldTuple(intConstVars, func, intpl);
           (boolConstVars, intpl) = List.mapFoldTuple(boolConstVars, func, intpl);
           (stringConstVars, intpl) = List.mapFoldTuple(stringConstVars, func, intpl);
           (jacobianVars, intpl) = List.mapFoldTuple(jacobianVars, func, intpl);
           (realOptimizeConstraintsVars, intpl) = List.mapFoldTuple(realOptimizeConstraintsVars, func, intpl);
           (realOptimizeFinalConstraintsVars, intpl) = List.mapFoldTuple(realOptimizeFinalConstraintsVars, func, intpl);


         then (SimCodeVar.SIMVARS(stateVars, derivativeVars, algVars, discreteAlgVars, intAlgVars, boolAlgVars, inputVars, outputVars, aliasVars, intAliasVars, boolAliasVars,
                  paramVars, intParamVars, boolParamVars, stringAlgVars, stringParamVars, stringAliasVars, extObjVars, constVars, intConstVars, boolConstVars, stringConstVars, jacobianVars,realOptimizeConstraintsVars, realOptimizeFinalConstraintsVars), intpl);
    case (_, _, _) then fail();
  end match;
end traveseSimVars;


protected function traverseExpsSimCode
  input SimCode.SimCode simCode;
  input Func func;
  input A ia;
  output SimCode.SimCode outSimCode;
  output A oa;
  replaceable type A subtypeof Any;
  partial function Func
    input DAE.Exp inExp;
    input A inTypeA;
    output DAE.Exp outExp;
    output A outA;
  end Func;
algorithm
  (outSimCode, oa) := match (simCode, func, ia)
    local
      SimCode.ModelInfo modelInfo;
      list<DAE.Exp> literals "shared literals";
      list<SimCode.RecordDeclaration> recordDecls;
      list<String> externalFunctionIncludes;
      list<SimCode.SimEqSystem> allEquations;
      list<list<SimCode.SimEqSystem>> odeEquations;
      list<list<SimCode.SimEqSystem>> algebraicEquations;
      list<SimCode.SimEqSystem> residualEquations;
      Boolean useSymbolicInitialization, useHomotopy;
      list<SimCode.SimEqSystem> initialEquations, removedInitialEquations;
      list<SimCode.SimEqSystem> startValueEquations;
      list<SimCode.SimEqSystem> nominalValueEquations;
      list<SimCode.SimEqSystem> minValueEquations;
      list<SimCode.SimEqSystem> maxValueEquations;
      list<SimCode.SimEqSystem> parameterEquations;
      list<SimCode.SimEqSystem> removedEquations;
      list<SimCode.SimEqSystem> algorithmAndEquationAsserts;
      list<SimCode.SimEqSystem> jacobianEquations;
      list<SimCode.SimEqSystem> equationsForZeroCrossings;
      list<SimCode.StateSet> stateSets;
      list<DAE.Constraint> constraints;
      list<DAE.ClassAttributes> classAttributes;
      list<BackendDAE.ZeroCrossing> zeroCrossings, relations;
      list<BackendDAE.TimeEvent> timeEvents;
      list<SimCode.SimWhenClause> whenClauses;
      list<DAE.ComponentRef> discreteModelVars;
      SimCode.ExtObjInfo extObjInfo;
      SimCode.MakefileParams makefileParams;
      SimCode.DelayedExpression delayedExps;
      list<SimCode.JacobianMatrix> jacobianMatrixes;
      Option<SimCode.SimulationSettings> simulationSettingsOpt;
      String fileNamePrefix;
      // *** a protected section *** not exported to SimCodeTV
      SimCode.HashTableCrefToSimVar crefToSimVarHT "hidden from typeview - used by cref2simvar() for cref -> SIMVAR lookup available in templates.";
      A a;
      Option<HpcOmSimCode.Schedule> hpcOmSchedule;
      Option<SimCode.BackendMapping> backendMapping;
      Option<HpcOmSimCode.MemoryMap> hpcOmMemory;
      list<SimCode.SimEqSystem> equationsForConditions;

    case (SimCode.SIMCODE(modelInfo, literals, recordDecls, externalFunctionIncludes,
                          allEquations, odeEquations, algebraicEquations, residualEquations,
                          useSymbolicInitialization, useHomotopy, initialEquations, removedInitialEquations, startValueEquations, nominalValueEquations, minValueEquations, maxValueEquations,
                          parameterEquations, removedEquations, algorithmAndEquationAsserts, equationsForZeroCrossings,
                          jacobianEquations, stateSets, constraints, classAttributes, zeroCrossings,
                          relations, timeEvents, whenClauses, discreteModelVars, extObjInfo, makefileParams,
                          delayedExps, jacobianMatrixes, simulationSettingsOpt, fileNamePrefix,
                          hpcOmSchedule,hpcOmMemory,equationsForConditions,crefToSimVarHT,backendMapping), _, a)
      equation
        (literals, a) = List.mapFold(literals, func, a);
        (allEquations, a) = traverseExpsEqSystems(allEquations, func, a, {});
        (odeEquations, a) = traverseExpsEqSystemsList(odeEquations, func, a, {});
        (algebraicEquations, a) = traverseExpsEqSystemsList(algebraicEquations, func, a, {});
        (residualEquations, a) = traverseExpsEqSystems(residualEquations, func, a, {});
        (initialEquations, a) = traverseExpsEqSystems(initialEquations, func, a, {});
        (removedInitialEquations, a) = traverseExpsEqSystems(removedInitialEquations, func, a, {});
        (startValueEquations, a) = traverseExpsEqSystems(startValueEquations, func, a, {});
        (nominalValueEquations, a) = traverseExpsEqSystems(nominalValueEquations, func, a, {});
        (minValueEquations, a) = traverseExpsEqSystems(minValueEquations, func, a, {});
        (maxValueEquations, a) = traverseExpsEqSystems(maxValueEquations, func, a, {});
        (parameterEquations, a) = traverseExpsEqSystems(parameterEquations, func, a, {});
        (removedEquations, a) = traverseExpsEqSystems(removedEquations, func, a, {});
        (algorithmAndEquationAsserts, a) = traverseExpsEqSystems(algorithmAndEquationAsserts, func, a, {});
        (jacobianEquations, a) = traverseExpsEqSystems(jacobianEquations, func, a, {});
        /* TODO:zeroCrossing */
        /* TODO:whenClauses */
        /* TODO:discreteModelVars */
        /* TODO:extObjInfo */
        /* TODO:delayedExps */
      then (SimCode.SIMCODE(modelInfo, literals, recordDecls, externalFunctionIncludes,
                            allEquations, odeEquations, algebraicEquations, residualEquations,
                            useSymbolicInitialization, useHomotopy, initialEquations, removedInitialEquations, startValueEquations, nominalValueEquations, minValueEquations, maxValueEquations,
                            parameterEquations, removedEquations, algorithmAndEquationAsserts, equationsForZeroCrossings,
                            jacobianEquations, stateSets, constraints, classAttributes, zeroCrossings,
                            relations, timeEvents, whenClauses, discreteModelVars, extObjInfo, makefileParams,
                            delayedExps, jacobianMatrixes, simulationSettingsOpt, fileNamePrefix,
                             hpcOmSchedule,hpcOmMemory, equationsForConditions, crefToSimVarHT, backendMapping), a);
  end match;
end traverseExpsSimCode;

protected function traverseExpsEqSystemsList
  input list<list<SimCode.SimEqSystem>> ieqs;
  input Func func;
  input A ia;
  input list<list<SimCode.SimEqSystem>> acc;
  output list<list<SimCode.SimEqSystem>> oeqs;
  output A oa;
  replaceable type A subtypeof Any;
  partial function Func
    input DAE.Exp inExp;
    input A inTypeA;
    output DAE.Exp outExp;
    output A outA;
  end Func;
algorithm
  (oeqs, oa) := match (ieqs, func, ia, acc)
    local
      list<SimCode.SimEqSystem> eq;
      A a;
      list<list<SimCode.SimEqSystem>> eqs;

    case ({}, _, a, _) then (listReverse(acc), a);
    case (eq::eqs, _, a, _)
      equation
        (eq, a) = traverseExpsEqSystems(eq, func, a, {});
        (oeqs, a) = traverseExpsEqSystemsList(eqs, func, a, eq::acc);
      then (oeqs, a);
  end match;
end traverseExpsEqSystemsList;

protected function traverseExpsEqSystems
  input list<SimCode.SimEqSystem> ieqs;
  input Func func;
  input A ia;
  input list<SimCode.SimEqSystem> acc;
  output list<SimCode.SimEqSystem> oeqs;
  output A oa;
  replaceable type A subtypeof Any;
  partial function Func
    input DAE.Exp inExp;
    input A inTypeA;
    output DAE.Exp outExp;
    output A outA;
  end Func;
algorithm
  (oeqs, oa) := match (ieqs, func, ia, acc)
    local
      SimCode.SimEqSystem eq;
      A a;
      list<SimCode.SimEqSystem> eqs;

    case ({}, _, a, _) then (listReverse(acc), a);
    case (eq::eqs, _, a, _)
      equation
        (eq, a) = traverseExpsEqSystem(eq, func, a);
        (oeqs, a) = traverseExpsEqSystems(eqs, func, a, eq::acc);
      then (oeqs, a);
  end match;
end traverseExpsEqSystems;

protected function traverseExpsEqSystem
  input SimCode.SimEqSystem eq;
  input Func func;
  input A ia;
  output SimCode.SimEqSystem oeq;
  output A oa;
  replaceable type A subtypeof Any;
  partial function Func
    input DAE.Exp inExp;
    input A inTypeA;
    output DAE.Exp outExp;
    output A outA;
  end Func;
algorithm
  (oeq, oa) := match (eq, func, ia)
    local
      DAE.Exp exp, right;
      DAE.ComponentRef cr, left;
      list<tuple<Integer, Integer, SimCode.SimEqSystem>> simJac;
      list<DAE.Statement> stmts;
      list<DAE.ElementSource> sources;
      SimCode.SimEqSystem cont;
      list<SimCode.SimEqSystem> discEqs, eqs;
      Integer index, indexSys;
      Boolean partOfMixed;
      list<SimCodeVar.SimVar> vars, discVars;
      list<DAE.Exp> beqs;
      list<DAE.ComponentRef> crefs;
      list<DAE.ComponentRef> conditions;
      Boolean initialCall;
      Option<SimCode.SimEqSystem> elseWhen;
      list<tuple<DAE.Exp, list<SimCode.SimEqSystem>>> ifbranches;
      list<SimCode.SimEqSystem> elsebranch;
      DAE.ElementSource source;
      A a;
      Option<SimCode.JacobianMatrix> symJac;
      Boolean linearTearing;
      Boolean homotopySupport;
      Boolean mixedSystem;

    case (SimCode.SES_RESIDUAL(index, exp, source), _, a) equation
      (exp, a) = func(exp, a);
    then (SimCode.SES_RESIDUAL(index, exp, source), a);

    case (SimCode.SES_SIMPLE_ASSIGN(index, cr, exp, source), _, a) equation
      (exp, a) = func(exp, a);
    then (SimCode.SES_SIMPLE_ASSIGN(index, cr, exp, source), a);

    case (SimCode.SES_ARRAY_CALL_ASSIGN(index, cr, exp, source), _, a) equation
      (exp, a) = func(exp, a);
    then (SimCode.SES_ARRAY_CALL_ASSIGN(index, cr, exp, source), a);

    case (SimCode.SES_IFEQUATION(index, ifbranches, elsebranch, source), _, a)
      /* TODO: Me */
    then (SimCode.SES_IFEQUATION(index, ifbranches, elsebranch, source), a);

    case (SimCode.SES_ALGORITHM(index, stmts), _, a)
      /* TODO: Me */
    then (SimCode.SES_ALGORITHM(index, stmts), a);

    case (SimCode.SES_LINEAR(index, partOfMixed, vars, beqs, simJac, eqs, symJac, sources, indexSys), _, a)
      /* TODO: Me */
    then (SimCode.SES_LINEAR(index, partOfMixed, vars, beqs, simJac, eqs, symJac, sources, indexSys), a);

    case (SimCode.SES_NONLINEAR(index, eqs, crefs, indexSys, symJac, linearTearing, homotopySupport, mixedSystem), _, a)
      /* TODO: Me */
    then (SimCode.SES_NONLINEAR(index, eqs, crefs, indexSys, symJac, linearTearing, homotopySupport, mixedSystem), a);

    case (SimCode.SES_MIXED(index, cont, discVars, discEqs, indexSys), _, a)
      /* TODO: Me */
    then (SimCode.SES_MIXED(index, cont, discVars, discEqs, indexSys), a);

    case (SimCode.SES_WHEN(index, conditions, initialCall, left, right, elseWhen, source), _, a)
      /* TODO: Me */
    then (SimCode.SES_WHEN(index, conditions, initialCall, left, right, elseWhen, source), a);
  end match;
end traverseExpsEqSystem;

protected function setSimCodeLiterals
  input SimCode.SimCode simCode;
  input list<DAE.Exp> literals;
  output SimCode.SimCode outSimCode;
algorithm
  outSimCode := match (simCode, literals)
    local
      SimCode.ModelInfo modelInfo;
      list<SimCode.RecordDeclaration> recordDecls;
      list<String> externalFunctionIncludes;
      list<SimCode.SimEqSystem> allEquations;
      list<list<SimCode.SimEqSystem>> odeEquations;
      list<list<SimCode.SimEqSystem>> algebraicEquations;
      list<SimCode.SimEqSystem> residualEquations;
      Boolean useSymbolicInitialization, useHomotopy;
      list<SimCode.SimEqSystem> initialEquations, removedInitialEquations;
      list<SimCode.SimEqSystem> startValueEquations;
      list<SimCode.SimEqSystem> nominalValueEquations;
      list<SimCode.SimEqSystem> minValueEquations;
      list<SimCode.SimEqSystem> maxValueEquations;
      list<SimCode.SimEqSystem> parameterEquations;
      list<SimCode.SimEqSystem> removedEquations;
      list<SimCode.SimEqSystem> algorithmAndEquationAsserts;
      list<SimCode.SimEqSystem> jacobianEquations;
      list<SimCode.SimEqSystem> equationsForZeroCrossings;
      list<SimCode.StateSet> stateSets;
      list<DAE.Constraint> constraints;
      list<DAE.ClassAttributes> classAttributes;
      list<BackendDAE.ZeroCrossing> zeroCrossings, relations;
      list<BackendDAE.TimeEvent> timeEvents;
      list<SimCode.SimWhenClause> whenClauses;
      list<DAE.ComponentRef> discreteModelVars;
      SimCode.ExtObjInfo extObjInfo;
      SimCode.MakefileParams makefileParams;
      SimCode.DelayedExpression delayedExps;
      list<SimCode.JacobianMatrix> jacobianMatrixes;
      Option<SimCode.SimulationSettings> simulationSettingsOpt;
      String fileNamePrefix;
      // *** a protected section *** not exported to SimCodeTV
      SimCode.HashTableCrefToSimVar crefToSimVarHT "hidden from typeview - used by cref2simvar() for cref -> SIMVAR lookup available in templates.";
      Option<HpcOmSimCode.Schedule> hpcOmSchedule;
      Option<SimCode.BackendMapping> backendMapping;
      Option<HpcOmSimCode.MemoryMap> hpcOmMemory;
      list<SimCode.SimEqSystem> equationsForConditions;

    case (SimCode.SIMCODE(modelInfo, _, recordDecls, externalFunctionIncludes,
                          allEquations, odeEquations, algebraicEquations, residualEquations,
                          useSymbolicInitialization, useHomotopy, initialEquations, removedInitialEquations, startValueEquations, nominalValueEquations, minValueEquations, maxValueEquations,
                          parameterEquations, removedEquations, algorithmAndEquationAsserts, equationsForZeroCrossings,
                          jacobianEquations, stateSets, constraints, classAttributes, zeroCrossings,
                          relations, timeEvents, whenClauses, discreteModelVars, extObjInfo, makefileParams,
                          delayedExps, jacobianMatrixes, simulationSettingsOpt, fileNamePrefix, hpcOmSchedule, hpcOmMemory, equationsForConditions, crefToSimVarHT, backendMapping), _)
      then SimCode.SIMCODE(modelInfo, literals, recordDecls, externalFunctionIncludes,
                           allEquations, odeEquations, algebraicEquations, residualEquations,
                           useSymbolicInitialization, useHomotopy, initialEquations, removedInitialEquations, startValueEquations, nominalValueEquations, minValueEquations, maxValueEquations,
                           parameterEquations, removedEquations, algorithmAndEquationAsserts,equationsForZeroCrossings,
                           jacobianEquations, stateSets, constraints, classAttributes, zeroCrossings,
                           relations, timeEvents, whenClauses, discreteModelVars, extObjInfo, makefileParams,
                           delayedExps, jacobianMatrixes, simulationSettingsOpt, fileNamePrefix, hpcOmSchedule, hpcOmMemory, equationsForConditions, crefToSimVarHT, backendMapping);
  end match;
end setSimCodeLiterals;

protected function eqSystemWCET
  "Calculate the estimated worst-case execution time of the system for partitioning"
  input SimCode.SimEqSystem eqs;
  output tuple<SimCode.SimEqSystem, Integer> tpl;
protected
  Integer i;
algorithm
  (_, i) := traverseExpsEqSystems({eqs}, Expression.complexityTraverse, 0, {});
  tpl := (eqs, i);
end eqSystemWCET;

public function isParallelFunctionContext
  input SimCode.Context context;
  output Boolean outBool;
algorithm
  outBool := match(context)
    case (SimCode.PARALLEL_FUNCTION_CONTEXT()) then true;
    else false;
  end match;
end isParallelFunctionContext;

protected function getProtected
  input Option<DAE.VariableAttributes> attr;
  output Boolean b;
algorithm
  b := match attr
    case SOME(DAE.VAR_ATTR_REAL(isProtected=SOME(b))) then b;
    case SOME(DAE.VAR_ATTR_INT(isProtected=SOME(b))) then b;
    case SOME(DAE.VAR_ATTR_BOOL(isProtected=SOME(b))) then b;
    case SOME(DAE.VAR_ATTR_STRING(isProtected=SOME(b))) then b;
    case SOME(DAE.VAR_ATTR_ENUMERATION(isProtected=SOME(b))) then b;
    else false;
  end match;
end getProtected;

public function createIdxSCVarMapping "author: marcusw
  Create a mapping from the SCVar-Index (array-Index) to the SCVariable."
  input SimCodeVar.SimVars simVars;
  output array<Option<SimCodeVar.SimVar>> oMapping;
protected
  Integer numStateVars;
  list<SimCodeVar.SimVar> stateVars;
  list<SimCodeVar.SimVar> derivativeVars;
  list<SimCodeVar.SimVar> algVars;
  list<SimCodeVar.SimVar> discreteAlgVars;
  list<SimCodeVar.SimVar> intAlgVars;
  list<SimCodeVar.SimVar> boolAlgVars;
  list<SimCodeVar.SimVar> inputVars;
  list<SimCodeVar.SimVar> outputVars;
  list<SimCodeVar.SimVar> aliasVars;
  list<SimCodeVar.SimVar> intAliasVars;
  list<SimCodeVar.SimVar> boolAliasVars;
  list<SimCodeVar.SimVar> paramVars;
  list<SimCodeVar.SimVar> intParamVars;
  list<SimCodeVar.SimVar> boolParamVars;
  list<SimCodeVar.SimVar> stringAlgVars;
  list<SimCodeVar.SimVar> stringParamVars;
  list<SimCodeVar.SimVar> stringAliasVars;
  list<SimCodeVar.SimVar> extObjVars;
  list<SimCodeVar.SimVar> constVars;
  list<SimCodeVar.SimVar> intConstVars;
  list<SimCodeVar.SimVar> boolConstVars;
  list<SimCodeVar.SimVar> stringConstVars;
  list<SimCodeVar.SimVar> jacobianVars;
  list<SimCodeVar.SimVar> realOptimizeConstraintsVars;
  list<SimCodeVar.SimVar> realOptimizeFinalConstraintsVars;
  list<tuple<Integer,SimCodeVar.SimVar>> idxSimVarMappingTplList;
  Integer highestIdx, varCount;
  array<Option<SimCodeVar.SimVar>> mappingArray;
algorithm
  SimCodeVar.SIMVARS(stateVars, derivativeVars, algVars, discreteAlgVars, intAlgVars, boolAlgVars, inputVars,
      outputVars, aliasVars, intAliasVars, boolAliasVars, paramVars, intParamVars, boolParamVars,
      stringAlgVars, stringParamVars, stringAliasVars, extObjVars, constVars, intConstVars, boolConstVars, stringConstVars, jacobianVars, realOptimizeConstraintsVars, realOptimizeFinalConstraintsVars) := simVars;

  numStateVars := listLength(stateVars);
  varCount := 0;
  ((idxSimVarMappingTplList, highestIdx)) := List.fold1(stateVars, createAllSCVarMapping0, varCount, ({},0));
  varCount := varCount + numStateVars;
  ((idxSimVarMappingTplList, highestIdx)) := List.fold1(derivativeVars, createAllSCVarMapping0, varCount, (idxSimVarMappingTplList,highestIdx));
  varCount := varCount + numStateVars;
  ((idxSimVarMappingTplList, highestIdx)) := List.fold1(algVars, createAllSCVarMapping0, varCount, (idxSimVarMappingTplList,highestIdx));
  varCount := varCount + listLength(algVars);
  ((idxSimVarMappingTplList, highestIdx)) := List.fold1(discreteAlgVars, createAllSCVarMapping0, varCount, (idxSimVarMappingTplList,highestIdx));
  varCount := varCount + listLength(discreteAlgVars);
  ((idxSimVarMappingTplList, highestIdx)) := List.fold1(intAlgVars, createAllSCVarMapping0, varCount, (idxSimVarMappingTplList,highestIdx));
  varCount := varCount + listLength(intAlgVars);
  ((idxSimVarMappingTplList, highestIdx)) := List.fold1(boolAlgVars, createAllSCVarMapping0, varCount, (idxSimVarMappingTplList,highestIdx));
  //((idxSimVarMappingTplList, highestIdx)) := List.fold1(inputVars, createAllSCVarMapping0, numStateVars, (idxSimVarMappingTplList,highestIdx));
  //((idxSimVarMappingTplList, highestIdx)) := List.fold1(outputVars, createAllSCVarMapping0, numStateVars, (idxSimVarMappingTplList,highestIdx));
  //((idxSimVarMappingTplList, highestIdx)) := List.fold1(aliasVars, createAllSCVarMapping0, numStateVars, (idxSimVarMappingTplList,highestIdx));
  //((idxSimVarMappingTplList, highestIdx)) := List.fold1(intAliasVars, createAllSCVarMapping0, numStateVars, (idxSimVarMappingTplList,highestIdx));
  //((idxSimVarMappingTplList, highestIdx)) := List.fold1(boolAliasVars, createAllSCVarMapping0, numStateVars, (idxSimVarMappingTplList,highestIdx));
  //((idxSimVarMappingTplList, highestIdx)) := List.fold1(paramVars, createAllSCVarMapping0, numStateVars, (idxSimVarMappingTplList,highestIdx));
  //((idxSimVarMappingTplList, highestIdx)) := List.fold1(intParamVars, createAllSCVarMapping0, numStateVars, (idxSimVarMappingTplList,highestIdx));
  //((idxSimVarMappingTplList, highestIdx)) := List.fold1(boolParamVars, createAllSCVarMapping0, numStateVars, (idxSimVarMappingTplList,highestIdx));
  //((idxSimVarMappingTplList, highestIdx)) := List.fold1(stringAlgVars, createAllSCVarMapping0, numStateVars, (idxSimVarMappingTplList,highestIdx));
  //((idxSimVarMappingTplList, highestIdx)) := List.fold1(stringParamVars, createAllSCVarMapping0, numStateVars, (idxSimVarMappingTplList,highestIdx));
  //((idxSimVarMappingTplList, highestIdx)) := List.fold1(stringAliasVars, createAllSCVarMapping0, numStateVars, (idxSimVarMappingTplList,highestIdx));
  //((idxSimVarMappingTplList, highestIdx)) := List.fold1(extObjVars, createAllSCVarMapping0, numStateVars, (idxSimVarMappingTplList,highestIdx));
  //((idxSimVarMappingTplList, highestIdx)) := List.fold1(constVars, createAllSCVarMapping0, numStateVars, (idxSimVarMappingTplList,highestIdx));
  //((idxSimVarMappingTplList, highestIdx)) := List.fold1(intConstVars, createAllSCVarMapping0, numStateVars, (idxSimVarMappingTplList,highestIdx));
  //((idxSimVarMappingTplList, highestIdx)) := List.fold1(boolConstVars, createAllSCVarMapping0, numStateVars, (idxSimVarMappingTplList,highestIdx));
  //((idxSimVarMappingTplList, highestIdx)) := List.fold1(stringConstVars, createAllSCVarMapping0, numStateVars, (idxSimVarMappingTplList,highestIdx));
  //((idxSimVarMappingTplList, highestIdx)) := List.fold1(jacobianVars, createAllSCVarMapping0, numStateVars, (idxSimVarMappingTplList,highestIdx));
  //((idxSimVarMappingTplList, highestIdx)) := List.fold1(realOptimizeConstraintsVars, createAllSCVarMapping0, numStateVars, (idxSimVarMappingTplList,highestIdx));

  mappingArray := arrayCreate(highestIdx, NONE());
  mappingArray := List.fold(idxSimVarMappingTplList, createAllSCVarMapping1, mappingArray);
  oMapping := mappingArray;
end createIdxSCVarMapping;

protected function createAllSCVarMapping0 "author: marcusw
  Append the given variable to the Index/SimVar-List."
  input SimCodeVar.SimVar iSimVar;
  input Integer iOffset; //an offset that should be added to the index (necessary for state derivatives)
  input tuple<list<tuple<Integer,SimCodeVar.SimVar>>, Integer> iSimVarIdxMapping;
  output tuple<list<tuple<Integer,SimCodeVar.SimVar>>, Integer> oSimVarIdxMapping; //<mapping index -> simvar, highestIndex>
protected
  Integer simVarIdx, highestIdx;
  list<tuple<Integer,SimCodeVar.SimVar>> iMapping;
algorithm
  (iMapping,highestIdx) := iSimVarIdxMapping;
  //print("createAllSCVarMapping0: " + intString(highestIdx) + "\n");
  SimCodeVar.SIMVAR(index=simVarIdx) := iSimVar;
  simVarIdx := simVarIdx + 1 + iOffset;
  highestIdx := if intGt(simVarIdx, highestIdx) then simVarIdx else highestIdx;
  iMapping := (simVarIdx, iSimVar)::iMapping;
  //print("createAllSCVarMapping0: Mapping-Length: " + intString(listLength(iMapping)) + "\n");
  oSimVarIdxMapping := (iMapping,highestIdx);
end createAllSCVarMapping0;

protected function createAllSCVarMapping1 "author: marcusw
  Set the arrayIndex (iMapping) to the value given by the tuple."
  input tuple<Integer,SimCodeVar.SimVar> iSimVarIdxTpl; //<idx, elem>
  input array<Option<SimCodeVar.SimVar>> iMapping;
  output array<Option<SimCodeVar.SimVar>> oMapping;
protected
  Integer simVarIdx;
  SimCodeVar.SimVar simVar;
algorithm
  (simVarIdx,simVar) := iSimVarIdxTpl;
  oMapping := arrayUpdate(iMapping,simVarIdx,SOME(simVar));
end createAllSCVarMapping1;


protected function aliasRecordDeclarations
  input SimCode.RecordDeclaration inDecl;
  input HashTableStringToPath.HashTable inHt;
  output SimCode.RecordDeclaration decl;
  output HashTableStringToPath.HashTable ht;
algorithm
  (decl,ht) := match (inDecl,inHt)
    local
      list<SimCode.Variable> vars;
      Absyn.Path name;
      String str,sname;
      Option<String> alias;
    case (SimCode.RECORD_DECL_FULL(sname, _, name, vars),_)
      equation
        str = stringDelimitList(List.map(vars, variableString), "\n");
        (alias,ht) = aliasRecordDeclarations2(str, name, inHt);
      then (SimCode.RECORD_DECL_FULL(sname, alias, name, vars),ht);
    else (inDecl,inHt);
  end match;
end aliasRecordDeclarations;

protected function aliasRecordDeclarations2
  input String str;
  input Absyn.Path path;
  input HashTableStringToPath.HashTable inHt;
  output Option<String> alias;
  output HashTableStringToPath.HashTable ht;
algorithm
  (alias,ht) := matchcontinue (str,path,inHt)
    local
      String aliasStr;
    case (_,_,_)
      equation
        aliasStr = Absyn.pathStringUnquoteReplaceDot(BaseHashTable.get(str, inHt),"_");
      then (SOME(aliasStr),inHt);
    else
      equation
        ht = BaseHashTable.add((str,path),inHt);
      then (NONE(),ht);
  end matchcontinue;
end aliasRecordDeclarations2;

protected function variableString
  input SimCode.Variable var;
  output String str;
algorithm
  str := match var
    local
      DAE.ComponentRef name;
      DAE.Type ty;
    case SimCode.VARIABLE(name=name, ty=ty)
      then Types.unparseType(ty) + " " + ComponentReference.printComponentRefStr(name);
    case SimCode.FUNCTION_PTR(name=str)
      then "modelica_fnptr " + str;
  end match;
end variableString;

public function getEnumerationTypes
  input SimCodeVar.SimVars inVars;
  output list<SimCodeVar.SimVar> outVars;
algorithm
  outVars := match (inVars)
    local
      list<SimCodeVar.SimVar> stateVars_;
      list<SimCodeVar.SimVar> derivativeVars_;
      list<SimCodeVar.SimVar> algVars_;
      list<SimCodeVar.SimVar> discreteAlgVars_;
      list<SimCodeVar.SimVar> intAlgVars_;
      list<SimCodeVar.SimVar> boolAlgVars_;
      list<SimCodeVar.SimVar> inputVars_;
      list<SimCodeVar.SimVar> outputVars_;
      list<SimCodeVar.SimVar> aliasVars_;
      list<SimCodeVar.SimVar> intAliasVars_;
      list<SimCodeVar.SimVar> boolAliasVars_;
      list<SimCodeVar.SimVar> paramVars_;
      list<SimCodeVar.SimVar> intParamVars_;
      list<SimCodeVar.SimVar> boolParamVars_;
      list<SimCodeVar.SimVar> stringAlgVars_;
      list<SimCodeVar.SimVar> stringParamVars_;
      list<SimCodeVar.SimVar> stringAliasVars_;
      list<SimCodeVar.SimVar> extObjVars_;
      list<SimCodeVar.SimVar> constVars_;
      list<SimCodeVar.SimVar> intConstVars_;
      list<SimCodeVar.SimVar> boolConstVars_;
      list<SimCodeVar.SimVar> stringConstVars_;
      list<SimCodeVar.SimVar> jacobianVars_;
      list<SimCodeVar.SimVar> realOptimizeConstraintsVars_;
      list<SimCodeVar.SimVar> realOptimizeFinalConstraintsVars_;
      list<SimCodeVar.SimVar> enumTypesList;
    case (SimCodeVar.SIMVARS(stateVars = stateVars_, derivativeVars = derivativeVars_, algVars = algVars_, discreteAlgVars = discreteAlgVars_, intAlgVars = intAlgVars_,
                          boolAlgVars = boolAlgVars_, inputVars = inputVars_, outputVars = outputVars_, aliasVars = aliasVars_, intAliasVars = intAliasVars_,
                          boolAliasVars = boolAliasVars_, paramVars = paramVars_, intParamVars = intParamVars_, boolParamVars = boolParamVars_,
                          stringAlgVars = stringAlgVars_, stringParamVars = stringParamVars_, stringAliasVars = stringAliasVars_, extObjVars = extObjVars_,
                          constVars = constVars_, intConstVars = intConstVars_, boolConstVars = boolConstVars_, stringConstVars = stringConstVars_,
                          jacobianVars = jacobianVars_, realOptimizeConstraintsVars = realOptimizeConstraintsVars_, realOptimizeFinalConstraintsVars = realOptimizeFinalConstraintsVars_))
      equation
        enumTypesList = getEnumerationTypesHelper(stateVars_, {});
        enumTypesList = getEnumerationTypesHelper(derivativeVars_, enumTypesList);
        enumTypesList = getEnumerationTypesHelper(algVars_, enumTypesList);
        enumTypesList = getEnumerationTypesHelper(discreteAlgVars_, enumTypesList);
        enumTypesList = getEnumerationTypesHelper(intAlgVars_, enumTypesList);
        enumTypesList = getEnumerationTypesHelper(boolAlgVars_, enumTypesList);
        enumTypesList = getEnumerationTypesHelper(inputVars_, enumTypesList);
        enumTypesList = getEnumerationTypesHelper(outputVars_, enumTypesList);
        enumTypesList = getEnumerationTypesHelper(aliasVars_, enumTypesList);
        enumTypesList = getEnumerationTypesHelper(intAliasVars_, enumTypesList);
        enumTypesList = getEnumerationTypesHelper(boolAliasVars_, enumTypesList);
        enumTypesList = getEnumerationTypesHelper(paramVars_, enumTypesList);
        enumTypesList = getEnumerationTypesHelper(intParamVars_, enumTypesList);
        enumTypesList = getEnumerationTypesHelper(boolParamVars_, enumTypesList);
        enumTypesList = getEnumerationTypesHelper(stringAlgVars_, enumTypesList);
        enumTypesList = getEnumerationTypesHelper(stringParamVars_, enumTypesList);
        enumTypesList = getEnumerationTypesHelper(stringAliasVars_, enumTypesList);
        enumTypesList = getEnumerationTypesHelper(extObjVars_, enumTypesList);
        enumTypesList = getEnumerationTypesHelper(constVars_, enumTypesList);
        enumTypesList = getEnumerationTypesHelper(intConstVars_, enumTypesList);
        enumTypesList = getEnumerationTypesHelper(boolConstVars_, enumTypesList);
        enumTypesList = getEnumerationTypesHelper(stringConstVars_, enumTypesList);
        enumTypesList = getEnumerationTypesHelper(jacobianVars_, enumTypesList);
        enumTypesList = getEnumerationTypesHelper(realOptimizeConstraintsVars_, enumTypesList);
        enumTypesList = getEnumerationTypesHelper(realOptimizeFinalConstraintsVars_, enumTypesList);

      then
        enumTypesList;
    case (_) then {};
  end match;
end getEnumerationTypes;

protected function getEnumerationTypesHelper
  input list<SimCodeVar.SimVar> inVars;
  input list<SimCodeVar.SimVar> inExistsList;
  output list<SimCodeVar.SimVar> outVars;
algorithm
  outVars := matchcontinue (inVars, inExistsList)
    local
      list<SimCodeVar.SimVar> vars;
      list<SimCodeVar.SimVar> existsList;
      SimCodeVar.SimVar var;
      DAE.Type ty;
    case (((var as SimCodeVar.SIMVAR(type_ = ty)) :: vars), existsList)
      equation
        true = Types.isEnumeration(ty);
        false = List.exist1(existsList, enumerationTypeExists, ty);
        existsList = listAppend(existsList, {var});
        existsList = getEnumerationTypesHelper(vars, existsList);
      then
        existsList;
    case ((_ :: vars), existsList)
      equation
        existsList = getEnumerationTypesHelper(vars, existsList);
      then
        existsList;
    case ({}, existsList) then existsList;
  end matchcontinue;
end getEnumerationTypesHelper;

protected function enumerationTypeExists
  input SimCodeVar.SimVar var;
  input DAE.Type inType;
  output Boolean b;
algorithm
  b := match (var, inType)
    local
      DAE.Type ty, ty1;
      Boolean res;
    case (SimCodeVar.SIMVAR(type_ = ty), ty1)
      equation
        res = stringEq(Types.unparseType(ty), Types.unparseType(ty1));
      then res;
    else false;
  end match;
end enumerationTypeExists;

protected function variableName
  input SimCode.Variable v;
  output String s;
algorithm
  s := match v
    case SimCode.VARIABLE(name=DAE.CREF_IDENT(ident=s)) then s;
    case SimCode.FUNCTION_PTR(name=s) then s;
  end match;
end variableName;

protected function compareVariable
  input SimCode.Variable v1;
  input SimCode.Variable v2;
  output Boolean b;
algorithm
  b := stringCompare(variableName(v1),variableName(v2)) > 0;
end compareVariable;

public function equationIndex
  input SimCode.SimEqSystem eq;
  output Integer index;
algorithm
  index := match eq
    case SimCode.SES_RESIDUAL(index=index) then index;
    case SimCode.SES_SIMPLE_ASSIGN(index=index) then index;
    case SimCode.SES_ARRAY_CALL_ASSIGN(index=index) then index;
    case SimCode.SES_IFEQUATION(index=index) then index;
    case SimCode.SES_ALGORITHM(index=index) then index;
    case SimCode.SES_LINEAR(index=index) then index;
    case SimCode.SES_NONLINEAR(index=index) then index;
    case SimCode.SES_MIXED(index=index) then index;
    case SimCode.SES_WHEN(index=index) then index;
    else
      equation
        Error.addMessage(Error.INTERNAL_ERROR,{"SimCode.equationIndex failed"});
      then fail();
  end match;
end equationIndex;

public function equationIndexEqual
  input SimCode.SimEqSystem eq1;
  input SimCode.SimEqSystem eq2;
  output Boolean isEqual;
algorithm
  isEqual := intEq(eqIndex(eq1),eqIndex(eq2));
end equationIndexEqual;

//--------------------------
// backendMapping section
//--------------------------

protected function setUpBackendMapping"sets up a BackendMapping type with empty eq and varmappings and empty adjacency matrices.
author: Waurich TUD 2014-04"
  input BackendDAE.BackendDAE dae;
  output SimCode.BackendMapping mapping;
algorithm
  mapping := matchcontinue(dae)
    local
      Integer sizeE,sizeV;
      array<Integer> eqMatch, varMatch;
      array<list<Integer>> tree;
      BackendDAE.EqSystems eqs;
      BackendDAE.IncidenceMatrix m;
      BackendDAE.IncidenceMatrixT mt;
      list<BackendDAE.IncidenceMatrix> mLst;
      list<BackendDAE.IncidenceMatrixT> mtLst;
      list<tuple<Integer,Integer>> varMap;
      list<tuple<Integer,list<Integer>>> eqMap;
      array<list<SimCodeVar.SimVar>> simVarMapping;
      list<tuple<Integer,Integer,BackendDAE.IncidenceMatrix,BackendDAE.IncidenceMatrixT,array<Integer>,array<Integer>>> tpl;
    case(_)
      equation
        BackendDAE.DAE(eqs=eqs) = dae;
        tpl = List.map(eqs,setUpSystMapping);
        sizeE = List.fold(List.map(tpl,Util.tuple61),intAdd,0);
        sizeV = List.fold(List.map(tpl,Util.tuple62),intAdd,0);
        eqMap = {};
        varMap = {};
        simVarMapping = arrayCreate(sizeV,{});
        eqMatch = arrayCreate(sizeE,0);
        varMatch = arrayCreate(sizeV,0);
        m = arrayCreate(sizeE,{});
        mt = arrayCreate(sizeV,{});
        ((_,_,m,mt,eqMatch,varMatch)) = List.fold(tpl,appendAdjacencyMatrices,(0,0,m,mt,eqMatch,varMatch));
        tree = arrayCreate(sizeE,{});
        tree = List.fold4(List.intRange(sizeE),setUpEqTree,m,mt,eqMatch,varMatch,tree);
        tree = Array.map(tree,List.unique);
        mapping = SimCode.BACKENDMAPPING(m,mt,eqMap,varMap,eqMatch,varMatch,tree,simVarMapping);
      then
        mapping;
    else
      then
        SimCode.NO_MAPPING();
  end matchcontinue;
end setUpBackendMapping;

protected function setUpEqTree" builds the tree graph. the index depicts an equation and the entry depicts the direct predecessors.
author:Waurich TUD 2014-04"
  input Integer beq;
  input BackendDAE.IncidenceMatrix m;
  input BackendDAE.IncidenceMatrixT mt;
  input array<Integer> eqMatch;
  input array<Integer> varMatch;
  input array<list<Integer>> treeIn;
  output array<list<Integer>> treeOut;
protected
  Integer assVar;
  list<Integer> preEqs,depVars;
algorithm
  assVar := arrayGet(eqMatch,beq);
  depVars := arrayGet(m,beq);
  depVars := List.filter1OnTrue(depVars,intGt,0);
  depVars := List.filter1OnTrue(depVars,intNe,assVar);
  preEqs := List.map1(depVars,Array.getIndexFirst,varMatch);
  Array.updateElementListAppend(beq,preEqs,treeIn);
  treeOut := treeIn;
end setUpEqTree;

protected function appendAdjacencyMatrices"appends the adjacencymatrices for the different equation systems.
the indeces are raised according to the number of equations and vars in the previous systems
author:Waurich TUD 2014-04"
  input tuple<Integer,Integer,BackendDAE.IncidenceMatrix,BackendDAE.IncidenceMatrixT,array<Integer>,array<Integer>> tplIn;
  input tuple<Integer,Integer,BackendDAE.IncidenceMatrix,BackendDAE.IncidenceMatrixT,array<Integer>,array<Integer>> foldIn;
  output tuple<Integer,Integer,BackendDAE.IncidenceMatrix,BackendDAE.IncidenceMatrixT,array<Integer>,array<Integer>> foldOut;
algorithm
  foldOut := match(tplIn,foldIn)
    local
      Integer sizeE,sizeV,addV,addE;
      array<Integer> eqMatch,varMatch,eqMatchIn,varMatchIn;
      BackendDAE.IncidenceMatrix mIn,m;
      BackendDAE.IncidenceMatrixT mtIn,mt;
    case((addE,addV,m,mt,eqMatch,varMatch),(sizeE,sizeV,mIn,mtIn,eqMatchIn,varMatchIn))
      equation
        m = Array.map1(m,addIntLst,sizeV);
        mt = Array.map1(mt,addIntLst,sizeE);
        eqMatch = Array.map1(eqMatch,intAdd,sizeV);
        varMatch = Array.map1(varMatch,intAdd,sizeE);
        mIn = List.fold2(List.intRange(addE),updateInAdjacencyMatrix,sizeE,m,mIn);
        mtIn = List.fold2(List.intRange(addV),updateInAdjacencyMatrix,sizeV,mt,mtIn);
        eqMatchIn = List.fold2(List.intRange(addE),updateInMatching,sizeE,eqMatch,eqMatchIn);
        varMatchIn = List.fold2(List.intRange(addV),updateInMatching,sizeV,varMatch,varMatchIn);
      then
        ((sizeE+addE,sizeV+addV,mIn,mtIn,eqMatchIn,varMatchIn));
  end match;
end appendAdjacencyMatrices;

protected function updateInAdjacencyMatrix"updates a row in an adajcency matrix. thw row indeces are raised by the offset
author: Waurich TUD 2014-04"
  input Integer idx;
  input Integer offset;
  input BackendDAE.IncidenceMatrix mAppend;
  input BackendDAE.IncidenceMatrix mIn;
  output BackendDAE.IncidenceMatrix mOut;
protected
  list<Integer> entry;
algorithm
  entry := arrayGet(mAppend,idx);
  mOut := arrayUpdate(mIn,idx+offset,entry);
end updateInAdjacencyMatrix;

protected function updateInMatching"updates an entry in the matching. the indeces are raised by the offset
author: Waurich TUD 2014-04"
  input Integer idx;
  input Integer offset;
  input array<Integer> matchingAppend;
  input array<Integer> matchingIn;
  output array<Integer> matchingOut;
protected
  Integer entry;
algorithm
  entry := arrayGet(matchingAppend,idx);
  matchingOut := arrayUpdate(matchingIn,idx+offset,entry);
end updateInMatching;

protected function addIntLst"add an integer to every entry in the lst
author:Waurich TUD 2014-04"
  input list<Integer> lstIn;
  input Integer x;
  output list<Integer> lstOut;
algorithm
  lstOut := List.map1(lstIn,intAdd,x);
end addIntLst;

protected function setUpSystMapping"gets the mapping information for every system of equations in the backenddae.
author:Waurich TUD 2014-04"
  input BackendDAE.EqSystem dae;
  output tuple<Integer,Integer,BackendDAE.IncidenceMatrix,BackendDAE.IncidenceMatrixT,array<Integer>,array<Integer>> outTpl;
protected
  Integer sizeV,sizeE;
  array<Integer> ass1, ass2;
  BackendDAE.IncidenceMatrix m;
  BackendDAE.IncidenceMatrixT mt;
  BackendDAE.Matching matching;
algorithm
  outTpl := matchcontinue(dae)
  case(_)
    equation
      BackendDAE.EQSYSTEM(m=SOME(m),mT=SOME(mt),matching=matching)= dae;
      BackendDAE.MATCHING(ass1=ass1,ass2=ass2) = matching;
      sizeE = BackendDAEUtil.equationArraySizeDAE(dae);
      sizeV = BackendVariable.daenumVariables(dae);
    then
      ((sizeE,sizeV,m,mt,ass2,ass1));
  case(_)
    equation
      BackendDAE.EQSYSTEM(m=NONE(),mT=NONE(),matching=matching) = dae;
      BackendDAE.MATCHING(ass1=ass1,ass2=ass2) = matching;
      (_,m,mt) = BackendDAEUtil.getIncidenceMatrix(dae,BackendDAE.NORMAL(),NONE());
      sizeE = BackendDAEUtil.equationArraySizeDAE(dae);
      sizeV = BackendVariable.daenumVariables(dae);
    then
      ((sizeE,sizeV,m,mt,ass2,ass1));
  end matchcontinue;
end setUpSystMapping;

protected function setBackendVarMapping"sets the varmapping in the backendmapping.
author:Waurich TUD 2014-04"
  input BackendDAE.BackendDAE dae;
  input SimCode.HashTableCrefToSimVar ht;
  input SimCode.ModelInfo modelInfo;
  input SimCode.BackendMapping bmapIn;
  output SimCode.BackendMapping bmapOut;
algorithm
  bmapOut := matchcontinue(dae,ht,modelInfo,bmapIn)
    local
      array<Integer> eqMatch,varMatch;
      array<list<Integer>> tree;
      SimCode.VarInfo varInfo;
      SimCodeVar.SimVars allVars;
      list<Integer> bVarIdcs,simVarIdcs;
      list<BackendDAE.EqSystem> eqs;
      list<BackendDAE.Var> vars;
      list<DAE.ComponentRef> crefs;
      list<SimCodeVar.SimVar> simVars;
      list<tuple<Integer,list<Integer>>> eqMapping;
      list<tuple<Integer,Integer>> varMapping;
      BackendDAE.IncidenceMatrix m;
      BackendDAE.IncidenceMatrixT mt;
      array<list<SimCodeVar.SimVar>> simVarMapping;
    case(_,_,_,_)
      equation
        SimCode.BACKENDMAPPING(m=m,mT=mt,eqMapping=eqMapping,varMapping=varMapping,eqMatch=eqMatch,varMatch=varMatch,eqTree=tree,simVarMapping=simVarMapping) = bmapIn;
        SimCode.MODELINFO(varInfo=varInfo,vars=allVars) = modelInfo;
        BackendDAE.DAE(eqs=eqs) = dae;
        vars = BackendVariable.equationSystemsVarsLst(eqs,{});
        crefs = List.map(vars,BackendVariable.varCref);
        bVarIdcs = List.intRange(listLength(crefs));
        simVars = List.map1(crefs,get,ht);
        simVarIdcs = List.map2(simVars,getSimVarIndex,varInfo,allVars);
        varMapping = makeVarMapTuple(simVarIdcs,bVarIdcs,{});
        List.fold1(simVars, fillSimVarMapping, simVarMapping, 1);
        //print(stringDelimitList(List.map(crefs,ComponentReference.printComponentRefStr),"\n")+"\n");
        //List.map_0(simVars,dumpVar);
      then
        SimCode.BACKENDMAPPING(m,mt,eqMapping,varMapping,eqMatch,varMatch,tree,simVarMapping);
    else
      SimCode.NO_MAPPING();
  end matchcontinue;
end setBackendVarMapping;

protected function fillSimVarMapping "adds the given simvar to the mapping.
author:marcusw"
  input SimCodeVar.SimVar iSimVar;
  input array<list<SimCodeVar.SimVar>> iSimVarMapping;
  input Integer iVarIdx;
  output Integer oVarIdx;
algorithm
  _ := arrayUpdate(iSimVarMapping, iVarIdx, {iSimVar});
  oVarIdx := iVarIdx + 1;
end fillSimVarMapping;

protected function getSimVarIndex"gets the index from a SimVar and calculates the place in the localData array
author:Waurich TUD 2014-04"
  input SimCodeVar.SimVar var;
  input SimCode.VarInfo varInfo;
  input SimCodeVar.SimVars allVars;
  output Integer idx;
algorithm
  idx := matchcontinue(var,varInfo,allVars)
    local
      Boolean isState;
      Integer i, offset;
      list<Boolean> bLst;
      list<SimCodeVar.SimVar> states;
    case(_,_,_)
      equation
      // is stateVar
      SimCodeVar.SIMVARS(stateVars = states) = allVars;
      bLst = List.map1(states,compareSimVarName,var);
      isState = List.fold(bLst,boolOr,false);
      true = isState;
      SimCodeVar.SIMVAR(index=i) = var;
    then
      i;
    case(_,_,_)
      equation
      // is not a stateVar
      SimCodeVar.SIMVARS(stateVars = states) = allVars;
      bLst = List.map1(states,compareSimVarName,var);
      isState = List.fold(bLst,boolOr,false);
      false = isState;
      SimCode.VARINFO(numStateVars=offset) = varInfo;
      SimCodeVar.SIMVAR(index=i) = var;
    then
      i+2*offset;
  end matchcontinue;
end getSimVarIndex;

protected function makeVarMapTuple"builds a tuple for the varMapping. ((simvarindex,backendvarindex))
author:Waurich TUD 2014-04"
  input list<Integer> sVar;
  input list<Integer> bVar;
  input list<tuple<Integer,Integer>> foldIn;
  output list<tuple<Integer,Integer>> foldOut;
algorithm
  foldOut := match(sVar,bVar,foldIn)
    local
      Integer i1,i2;
      list<Integer> rest1,rest2;
      list<tuple<Integer,Integer>> fold;
    case({},{},_)
      then
        foldIn;
    case(i1::rest1,i2::rest2,_)
      equation
        fold = makeVarMapTuple(rest1,rest2,(i1,i2)::foldIn);
      then
        fold;
  end match;
end makeVarMapTuple;

protected function setEqMapping"updates the equation mapping for a given pair of simeqs and backend eqs.
author:Waurich TUD 2014-04"
  input list<Integer> simEqs;
  input list<Integer> bEq;
  input SimCode.BackendMapping mapIn;
  output SimCode.BackendMapping mapOut;
algorithm
  mapOut := match(simEqs,bEq,mapIn)
    local
      array<Integer> eqMatch,varMatch;
      array<list<Integer>> tree;
      list<tuple<Integer,list<Integer>>> eqMapping;
      list<tuple<Integer,Integer>> varMapping;
      BackendDAE.IncidenceMatrix m;
      BackendDAE.IncidenceMatrixT mt;
      array<list<SimCodeVar.SimVar>> simVarMapping;
    case(_,_,SimCode.BACKENDMAPPING(m=m,mT=mt,eqMapping=eqMapping,varMapping=varMapping,eqMatch=eqMatch,varMatch=varMatch,eqTree=tree,simVarMapping=simVarMapping))
      equation
        eqMapping = List.fold1(simEqs, appendEqIdcs, bEq, eqMapping);
      then
        SimCode.BACKENDMAPPING(m,mt,eqMapping,varMapping,eqMatch,varMatch,tree,simVarMapping);
    case(_,_,SimCode.NO_MAPPING())
      then
        mapIn;
  end match;
end setEqMapping;

protected function appendEqIdcs"appends an equation mapping tuple to the mapping list.
author:Waurich TUD 2014-04"
  input Integer iCurrentIdx;
  input list<Integer> iEqIdx;
  input list<tuple<Integer, list<Integer>>> iSccIdc;
  output list<tuple<Integer, list<Integer>>> oSccIdc;
algorithm
  oSccIdc:=(iCurrentIdx,iEqIdx)::iSccIdc;
end appendEqIdcs;

public function getSimVarsInSimEq"gets the indeces for the simVars occuring in the given simEq
author:Waurich TUD 2014-04"
  input Integer simEq;
  input SimCode.BackendMapping map;
  input Integer opt; //1: get all indeces from the incidenceMatrix, 2: get only positive entries, 3: get only negative entries
  output list<Integer> simVars;
protected
  list<Integer> bVars,bEqs;
  list<list<Integer>> bVarsLst;
  list<tuple<Integer,list<Integer>>> eqMapping;
  list<tuple<Integer,Integer>> varMapping;
  BackendDAE.IncidenceMatrix m;
  BackendDAE.IncidenceMatrixT mt;
algorithm
  SimCode.BACKENDMAPPING(m=m,mT=mt,eqMapping=eqMapping,varMapping=varMapping) := map;
  bEqs := getBackendEqsForSimEq(simEq,map);
  bVarsLst := List.map1(bEqs,Array.getIndexFirst,m);
  bVars := List.flatten(bVarsLst);
  bVars := if intEq(opt,2) then List.filter1OnTrue(bVars,intGt,0) else bVars;
  bVars := if intEq(opt,3) then List.filter1OnTrue(bVars,intLt,0) else bVars;
  if not List.isMemberOnTrue(opt,{1,2,3},intEq) then
    print("invalid option for getSimVarsInSimEq\n");
  end if;
  bVars := List.unique(bVars);
  bVars := List.map(bVars,intAbs);
  simVars := List.map1(bVars,getSimVarForBackendVar,map);
end getSimVarsInSimEq;

public function getSimEqsOfSimVar"gets the indeces for the simEqs for the given simVar
author:Waurich TUD 2014-04"
  input Integer simVar;
  input SimCode.BackendMapping map;
  input Integer opt; //1: complete incidence matrix row, 2: only positive entries, 3: only negative entries
  output list<Integer> simEqs;
protected
  Integer bVar;
  list<Integer> bEqs;
  list<tuple<Integer,list<Integer>>> eqMapping;
  list<tuple<Integer,Integer>> varMapping;
  BackendDAE.IncidenceMatrix m;
  BackendDAE.IncidenceMatrixT mt;
algorithm
  SimCode.BACKENDMAPPING(m=m,mT=mt,eqMapping=eqMapping,varMapping=varMapping) := map;
  bVar := getBackendVarForSimVar(simVar,map);
  bEqs := arrayGet(mt,bVar);
  bEqs := if intEq(opt,2) then List.filter1OnTrue(bEqs,intGt,0) else bEqs;
  bEqs := if intEq(opt,3) then List.filter1OnTrue(bEqs,intLt,0) else bEqs;
  if not List.isMemberOnTrue(opt,{1,2,3},intEq) then
    print("invalid option for getSimEqsOfSimVar\n");
  end if;
  bEqs := List.map(bEqs,intAbs);
  simEqs := List.map1(bEqs,getSimEqsForBackendEqs,map);
  simEqs := List.unique(simEqs);
end getSimEqsOfSimVar;

public function getReqSimEqSysForSimVar
  input Integer simVar;
  input SimCode.SimCode simCode;
  output list<SimCode.SimEqSystem> ses;
protected
  list<Integer> sesIdcs;
  list<SimCode.SimEqSystem> sesLst;
  SimCode.BackendMapping bmap;
  Option<SimCode.BackendMapping> bmapOpt;
algorithm
  SimCode.SIMCODE(allEquations=sesLst, backendMapping=bmapOpt) := simCode;
  bmap := Util.getOption(bmapOpt);
  sesIdcs := getReqSimEqsForSimVar(simVar,bmap);
  ses := List.map1(sesIdcs,getSimEqSysForIndex,sesLst);
end getReqSimEqSysForSimVar;

public function getSimEqSysForIndex
  input Integer idx;
  input list<SimCode.SimEqSystem> allSimEqs;
  output SimCode.SimEqSystem outSimEq;
algorithm
  outSimEq :=List.getMemberOnTrue(idx,allSimEqs,indexIsEqual);
end getSimEqSysForIndex;

protected function indexIsEqual
  input Integer idx;
  input SimCode.SimEqSystem ses;
  output Boolean b;
protected
  Integer idx2;
algorithm
  idx2 := equationIndex(ses);
  b := intEq(idx,idx2);
end indexIsEqual;

public function getReqSimEqsForSimVar"outputs the indeces for the required simEqSys for the indexed SimVar
author:Waurich TUD 2014-04"
  input Integer simVar;
  input SimCode.BackendMapping map;
  output list<Integer> simEqs;
protected
  Integer bVar,bEq;
  list<Integer> beqs;
  array<Integer> eqMatch,varMatch;
  array<list<Integer>> tree;
  BackendDAE.IncidenceMatrix m;
  BackendDAE.IncidenceMatrixT mt;
algorithm
  SimCode.BACKENDMAPPING(m=m,mT=mt,eqMatch=eqMatch,varMatch=varMatch,eqTree=tree) := map;
  bVar := getBackendVarForSimVar(simVar,map);
  bEq := arrayGet(varMatch,bVar);
  beqs := collectReqSimEqs(bEq,tree,{});
  simEqs := List.map1(beqs,getSimEqsForBackendEqs,map);
  simEqs := List.unique(simEqs);
end getReqSimEqsForSimVar;

public function getAssignedSimEqSysIdx"gets the index of the assigned simEqSys for the given simVar idx
author:Waurich TUD 2014-06"
  input Integer simVarIdx;
  input SimCode.BackendMapping map;
  output Integer simEqSysIdx;
protected
  Integer bVarIdx,bEqIdx;
  array<Integer> varMatch;
algorithm
  bVarIdx := getBackendVarForSimVar(simVarIdx,map);
  SimCode.BACKENDMAPPING(varMatch = varMatch) := map;
  bEqIdx := arrayGet(varMatch,bVarIdx);
  simEqSysIdx := getSimEqsForBackendEqs(bEqIdx,map);
end getAssignedSimEqSysIdx;

protected function collectReqSimEqs"gets the previously required equations from the tree and gets the required equations for them and so on
author:Waurich TUD 2014-04"
  input Integer eq;
  input array<list<Integer>> tree;
  input list<Integer> eqsIn;
  output list<Integer> eqsOut;
protected
  list<Integer> preEqs,reqEqs;
algorithm
  preEqs := arrayGet(tree,eq);
  (_,preEqs,_) := List.intersection1OnTrue(preEqs,eqsIn,intEq);
  reqEqs := listAppend(preEqs,eqsIn);
  eqsOut := List.fold1(preEqs,collectReqSimEqs,tree,reqEqs);
end collectReqSimEqs;

protected function getBackendVarForSimVar"outputs the backendVar indeces for the given SimVar index
author:Waurich TUD 2014-04"
  input Integer simVar;
  input SimCode.BackendMapping map;
  output Integer bVar;
protected
  list<tuple<Integer,Integer>> varMapping;
algorithm
  SimCode.BACKENDMAPPING(varMapping=varMapping) := map;
  ((_,bVar)):= List.getMemberOnTrue(simVar,varMapping,findSimVar);
end getBackendVarForSimVar;

protected function getSimVarForBackendVar"outputs the SimVar indeces for the given backendVar index
author:Waurich TUD 2014-04"
  input Integer bVar;
  input SimCode.BackendMapping map;
  output Integer simVar;
protected
  list<tuple<Integer,Integer>> varMapping;
algorithm
  SimCode.BACKENDMAPPING(varMapping=varMapping) := map;
  ((simVar,_)):= List.getMemberOnTrue(bVar,varMapping,findBackendVar);
end getSimVarForBackendVar;

protected function getBackendEqsForSimEq"outputs the backendEq indeces for the given SimEqSys index
author:Waurich TUD 2014-04"
  input Integer simEq;
  input SimCode.BackendMapping map;
  output list<Integer> bEqs;
protected
  list<tuple<Integer,list<Integer>>> eqMapping;
algorithm
  SimCode.BACKENDMAPPING(eqMapping=eqMapping) := map;
  ((_,bEqs)):= List.getMemberOnTrue(simEq,eqMapping,findSimEqs);
end getBackendEqsForSimEq;

protected function getSimEqsForBackendEqs"outputs the simEqSys index for the given backendEquation index
author:Waurich TUD 2014-04"
  input Integer bEq;
  input SimCode.BackendMapping map;
  output Integer simEq;
protected
  list<tuple<Integer,list<Integer>>> eqMapping;
algorithm
  SimCode.BACKENDMAPPING(eqMapping=eqMapping) := map;
  ((simEq,_)):= List.getMemberOnTrue(bEq,eqMapping,findBEqs);
end getSimEqsForBackendEqs;

protected function findSimVar"outputs true if the tuple contains mapping information about the SimVar
author:Waurich TUD 2014-04"
  input Integer simVar;
  input tuple<Integer,Integer> varTpl;
  output Boolean b;
protected
  Integer simVar1;
algorithm
  (simVar1,_) := varTpl;
  b := intEq(simVar,simVar1);
end findSimVar;

protected function findBackendVar"outputs true if the tuple contains mapping information about the SimVar
author:Waurich TUD 2014-04"
  input Integer bVar;
  input tuple<Integer,Integer> varTpl;
  output Boolean b;
protected
  Integer bVar1;
algorithm
  (_,bVar1) := varTpl;
  b := intEq(bVar,bVar1);
end findBackendVar;

protected function findSimEqs"outputs true if the tuple contains mapping information about the SimEquation
author:Waurich TUD 2014-04"
  input Integer simEq;
  input tuple<Integer,list<Integer>> eqTpl;
  output Boolean b;
protected
  Integer simEq1;
algorithm
  (simEq1,_) := eqTpl;
  b := intEq(simEq,simEq1);
end findSimEqs;

protected function findBEqs"outputs true if the tuple contains mapping information about the backend equation
author:Waurich TUD 2014-04"
  input Integer bEq;
  input tuple<Integer,list<Integer>> eqTpl;
  output Boolean b;
protected
  list<Integer> bEq1;
algorithm
  (_,bEq1) := eqTpl;
  b := listMember(bEq,bEq1);
end findBEqs;

/*
This is wrong!
public function getSimVarByIndex
  input Integer idx;
  input SimCodeVar.SimVars allSimVars;
  output SimCodeVar.SimVar simVar;
algorithm
  simVar := matchcontinue(idx,allSimVars)
    local
      Integer size,idx2;
      list<SimCodeVar.SimVar> stateVars,algVars;
      SimCodeVar.SimVar var;
  case(_,SimCodeVar.SIMVARS(stateVars=stateVars,algVars=algVars))
    equation
      size = listLength(stateVars);
      true = idx > size;
      //its not a stateVar
      idx2 = idx - 2*size + 1;
      var = listGet(algVars,idx2);
      then var;
  case(_,SimCodeVar.SIMVARS(stateVars=stateVars,algVars=algVars))
    equation
      size = listLength(stateVars);
      true = idx <= size;
      //its a stateVar
      var = listGet(stateVars,idx);
      then var;
  else
    equation
      print("SimCodeUtil.getSimVarByIndex failed!\n");
    then fail();
  end matchcontinue;
end getSimVarByIndex;
*/

public function getAssignedCrefsOfSimEq"gets the crefs of the vars that are assigned (the lhs) of the simEqSystems
author:Waurich TUD 2014-05"
  input Integer idx;
  input SimCode.SimCode simCode;
  output list<DAE.ComponentRef> crefsOut;
algorithm
  crefsOut := match(idx,simCode)
    local
      SimCode.SimEqSystem simEqSyst;
      list<SimCode.SimEqSystem> allEqs;
      list<DAE.ComponentRef> crefs;
    case(_,SimCode.SIMCODE(allEquations=allEqs))
      equation
        simEqSyst = List.getMemberOnTrue(idx,allEqs,indexIsEqual);
        crefs = getSimEqSystemCrefsLHS(simEqSyst);
    then crefs;
  end match;
end getAssignedCrefsOfSimEq;

protected function getSimEqSystemCrefsLHS"gets the crefs of the vars that are assigned (the lhs) for a simEqSystem
author:Waurich TUD 2014-05"
  input SimCode.SimEqSystem simEqSys;
  output list<DAE.ComponentRef> crefsOut;
algorithm
  crefsOut := match(simEqSys)
    local
      DAE.ComponentRef cref;
      list<DAE.ComponentRef> crefs,crefs2;
      list<SimCodeVar.SimVar> simVars;
      list<SimCode.SimEqSystem> residual;
    case(SimCode.SES_RESIDUAL())
      equation
        print("implement SES_RESIDUAL in SimCodeUtil.getSimEqSystemCrefsLHS!\n");
    then {};
    case(SimCode.SES_SIMPLE_ASSIGN(cref=cref))
      equation
    then {cref};
    case(SimCode.SES_ARRAY_CALL_ASSIGN(componentRef=cref))
      equation
    then {cref};
    case(SimCode.SES_IFEQUATION())
      equation
        print("implement SES_IFEQUATION in SimCodeUtil.getSimEqSystemCrefsLHS!\n");
    then {};
    case(SimCode.SES_ALGORITHM())
      equation
        print("implement SES_ALGORITHM in SimCodeUtil.getSimEqSystemCrefsLHS!\n");
    then {};
    case(SimCode.SES_LINEAR(vars=simVars,residual=residual))
      equation
        crefs2 = List.flatten(List.map(residual,getSimEqSystemCrefsLHS));
        crefs = List.map(simVars,varName);
        crefs = listAppend(crefs,crefs2);
    then crefs;
    case(SimCode.SES_NONLINEAR(crefs=crefs))
      equation
    then crefs;
    case(SimCode.SES_MIXED(discVars=simVars))
      equation
        crefs = List.map(simVars,varName);
    then crefs;
    case(SimCode.SES_WHEN(left=cref))
      equation
    then {cref};
  end match;
end getSimEqSystemCrefsLHS;

public function replaceSimVarName"updates the name of simVarIn.
author:Waurich TUD 2014-05"
  input DAE.ComponentRef cref;
  input SimCodeVar.SimVar simVarIn;
  output SimCodeVar.SimVar simVarOut;
protected
  BackendDAE.VarKind varKind;
  String comment, unit, displayUnit;
  Integer index;
  Option<DAE.Exp> minValue, maxValue, initialValue, nominalValue;
  Boolean isFixed;
  DAE.Type type_;
  Boolean isDiscrete, isValueChangeable;
  SimCodeVar.AliasVariable aliasvar;
  DAE.ElementSource source;
  SimCodeVar.Causality causality;
  Option<Integer> variable_index;
  Option<DAE.ComponentRef> arrayCref;
  list<String> numArrayElement;
  Boolean isProtected;
algorithm
  SimCodeVar.SIMVAR(varKind=varKind, comment=comment, unit=unit, displayUnit=displayUnit, index=index,
                         minValue=minValue, maxValue=maxValue, initialValue=initialValue, nominalValue=nominalValue,
                         isFixed=isFixed, type_=type_, isDiscrete=isDiscrete, arrayCref=arrayCref, aliasvar=aliasvar, source=source,
                         causality=causality, variable_index=variable_index, numArrayElement=numArrayElement, isValueChangeable=isValueChangeable, isProtected=isProtected) := simVarIn;
  simVarOut := SimCodeVar.SIMVAR(cref, varKind, comment, unit, displayUnit, index, minValue, maxValue, initialValue, nominalValue,
                         isFixed, type_, isDiscrete, arrayCref, aliasvar, source, causality, variable_index, numArrayElement, isValueChangeable, isProtected);
end replaceSimVarName;

public function replaceSimVarIndex"updates the index of simVarIn.
author:Waurich TUD 2014-05"
  input Integer idx;
  input SimCodeVar.SimVar simVarIn;
  output SimCodeVar.SimVar simVarOut;
protected
  DAE.ComponentRef cref;
  BackendDAE.VarKind varKind;
  String comment, unit, displayUnit;
  Option<DAE.Exp> minValue, maxValue, initialValue, nominalValue;
  Boolean isFixed;
  DAE.Type type_;
  Boolean isDiscrete, isValueChangeable;
  SimCodeVar.AliasVariable aliasvar;
  DAE.ElementSource source;
  SimCodeVar.Causality causality;
  Option<Integer> variable_index;
  Option<DAE.ComponentRef> arrayCref;
  list<String> numArrayElement;
  Boolean isProtected;
algorithm
  SimCodeVar.SIMVAR(name=cref, varKind=varKind, comment=comment, unit=unit, displayUnit=displayUnit,
                         minValue=minValue, maxValue=maxValue, initialValue=initialValue, nominalValue=nominalValue,
                         isFixed=isFixed, type_=type_, isDiscrete=isDiscrete, arrayCref=arrayCref, aliasvar=aliasvar, source=source,
                         causality=causality, variable_index=variable_index, numArrayElement=numArrayElement, isValueChangeable=isValueChangeable, isProtected=isProtected) := simVarIn;
  simVarOut := SimCodeVar.SIMVAR(cref, varKind, comment, unit, displayUnit, idx, minValue, maxValue, initialValue, nominalValue,
                         isFixed, type_, isDiscrete, arrayCref, aliasvar, source, causality, variable_index, numArrayElement, isValueChangeable, isProtected);
end replaceSimVarIndex;

public function addSimVarToAlgVars
  input SimCodeVar.SimVar simVar;
  input SimCode.SimCode simCodeIn;
  output SimCode.SimCode simCodeOut;
protected
      SimCode.ModelInfo modelInfo;
      list<DAE.Exp> literals;
      list<SimCode.RecordDeclaration> recordDecls;
      list<String> externalFunctionIncludes;
      list<list<SimCode.SimEqSystem>> eqsTmp;
      list<list<SimCode.SimEqSystem>> odeEquations, algebraicEquations;
      list<SimCode.SimEqSystem> allEquations, residualEquations, startValueEquations, nominalValueEquations, minValueEquations, maxValueEquations, parameterEquations, removedEquations, algorithmAndEquationAsserts, jacobianEquations, equationsForZeroCrossings;
      list<SimCode.StateSet> stateSets;
      Boolean useSymbolicInitialization, useHomotopy;
      list<SimCode.SimEqSystem> initialEquations, removedInitialEquations;
      list<DAE.Constraint> constraints;
      list<DAE.ClassAttributes> classAttributes;
      list<BackendDAE.ZeroCrossing> zeroCrossings, relations;
      list<SimCode.SimWhenClause> whenClauses;
      list<DAE.ComponentRef> discreteModelVars;
      SimCode.ExtObjInfo extObjInfo;
      SimCode.MakefileParams makefileParams;
      SimCode.DelayedExpression delayedExps;
      list<SimCode.JacobianMatrix> jacobianMatrixes;
      list<String> labels;
      Option<SimCode.SimulationSettings> simulationSettingsOpt;
      list<BackendDAE.TimeEvent> timeEvents;
      String fileNamePrefix;
      SimCode.HashTableCrefToSimVar crefToSimVarHT;
      Absyn.Path name;
      String description,directory;
      SimCode.VarInfo varInfo;
      SimCodeVar.SimVars vars;
      list<SimCode.Function> functions;
      SimCode.Files files;
      Option<HpcOmSimCode.Schedule> hpcOmSchedule;
      Option<SimCode.BackendMapping> backendMapping;
      Option<HpcOmSimCode.MemoryMap> hpcOmMemory;
      list<SimCode.SimEqSystem> equationsForConditions;
      list<SimCodeVar.SimVar> stateVars,derivativeVars,algVars,discreteAlgVars,intAlgVars,boolAlgVars,inputVars,outputVars,aliasVars,intAliasVars,boolAliasVars,paramVars,intParamVars,boolParamVars,stringAlgVars,stringParamVars,stringAliasVars,extObjVars,constVars,intConstVars,boolConstVars,stringConstVars,jacobianVars,realOptimizeConstraintsVars, realOptimizeFinalConstraintsVars;
algorithm
  simCodeOut := match(simVar,simCodeIn)
    case (_,SimCode.SIMCODE(modelInfo, literals, recordDecls, externalFunctionIncludes, allEquations, odeEquations, algebraicEquations, residualEquations, useSymbolicInitialization, useHomotopy, initialEquations, removedInitialEquations, startValueEquations, nominalValueEquations, minValueEquations, maxValueEquations,
                 parameterEquations, removedEquations, algorithmAndEquationAsserts, equationsForZeroCrossings, jacobianEquations, stateSets, constraints, classAttributes, zeroCrossings, relations, timeEvents, whenClauses,
                 discreteModelVars, extObjInfo, makefileParams, delayedExps, jacobianMatrixes, simulationSettingsOpt, fileNamePrefix, hpcOmSchedule, hpcOmMemory, equationsForConditions, crefToSimVarHT, backendMapping))
      equation
        SimCode.MODELINFO(name=name, description=description, directory=directory, varInfo=varInfo, vars=vars, functions=functions, labels=labels) = modelInfo;
        SimCodeVar.SIMVARS(stateVars=stateVars,derivativeVars=derivativeVars,algVars=algVars,discreteAlgVars=discreteAlgVars,intAlgVars=intAlgVars,boolAlgVars=boolAlgVars,inputVars=inputVars,outputVars=outputVars,aliasVars=aliasVars,intAliasVars=intAliasVars,boolAliasVars=boolAliasVars,paramVars=paramVars,intParamVars=intParamVars,boolParamVars=boolParamVars,stringAlgVars=stringAlgVars,
        stringParamVars=stringParamVars,stringAliasVars=stringAliasVars,extObjVars=extObjVars,constVars=constVars,intConstVars=intConstVars,boolConstVars=boolConstVars,stringConstVars=stringConstVars,jacobianVars=jacobianVars,realOptimizeConstraintsVars=realOptimizeConstraintsVars, realOptimizeFinalConstraintsVars = realOptimizeFinalConstraintsVars) = vars;
        algVars = listAppend(algVars,{simVar});
        vars = SimCodeVar.SIMVARS(stateVars,derivativeVars,algVars,discreteAlgVars,intAlgVars,boolAlgVars,inputVars,outputVars,aliasVars,intAliasVars,boolAliasVars,paramVars,intParamVars,boolParamVars,stringAlgVars,
        stringParamVars,stringAliasVars,extObjVars,constVars,intConstVars,boolConstVars,stringConstVars,jacobianVars,realOptimizeConstraintsVars, realOptimizeFinalConstraintsVars);
        modelInfo = SimCode.MODELINFO(name, description, directory, varInfo, vars, functions, labels);
      then
        SimCode.SIMCODE(modelInfo, literals, recordDecls, externalFunctionIncludes, allEquations, odeEquations, algebraicEquations, residualEquations, useSymbolicInitialization, useHomotopy, initialEquations, removedInitialEquations, startValueEquations, nominalValueEquations, minValueEquations, maxValueEquations,
                  parameterEquations, removedEquations, algorithmAndEquationAsserts, equationsForZeroCrossings, jacobianEquations, stateSets, constraints, classAttributes, zeroCrossings, relations, timeEvents, whenClauses,
                  discreteModelVars, extObjInfo, makefileParams, delayedExps, jacobianMatrixes, simulationSettingsOpt, fileNamePrefix, hpcOmSchedule, hpcOmMemory, equationsForConditions, crefToSimVarHT,backendMapping);
  end match;
end addSimVarToAlgVars;

public function addSimEqSysToODEquations"adds the given simEqSys to both to allEquations and odeEquations"
  input SimCode.SimEqSystem simEqSys;
  input Integer sysIdx;
  input SimCode.SimCode simCodeIn;
  output SimCode.SimCode simCodeOut;
protected
      SimCode.ModelInfo modelInfo;
      list<DAE.Exp> literals;
      list<SimCode.RecordDeclaration> recordDecls;
      list<String> externalFunctionIncludes;
      list<list<SimCode.SimEqSystem>> eqsTmp;
      list<list<SimCode.SimEqSystem>> odeEquations, algebraicEquations;
      list<SimCode.SimEqSystem> allEquations, residualEquations, startValueEquations, nominalValueEquations, minValueEquations, maxValueEquations, parameterEquations, removedEquations, algorithmAndEquationAsserts, jacobianEquations, equationsForZeroCrossings;
      list<SimCode.StateSet> stateSets;
      Boolean useSymbolicInitialization, useHomotopy;
      list<SimCode.SimEqSystem> initialEquations, removedInitialEquations, odes;
      list<DAE.Constraint> constraints;
      list<DAE.ClassAttributes> classAttributes;
      list<BackendDAE.ZeroCrossing> zeroCrossings, relations;
      list<SimCode.SimWhenClause> whenClauses;
      list<DAE.ComponentRef> discreteModelVars;
      SimCode.ExtObjInfo extObjInfo;
      SimCode.MakefileParams makefileParams;
      SimCode.DelayedExpression delayedExps;
      list<SimCode.JacobianMatrix> jacobianMatrixes;
      list<String> labels;
      Option<SimCode.SimulationSettings> simulationSettingsOpt;
      list<BackendDAE.TimeEvent> timeEvents;
      String fileNamePrefix;
      SimCode.HashTableCrefToSimVar crefToSimVarHT;
      Absyn.Path name;
      String description,directory;
      SimCode.VarInfo varInfo;
      SimCodeVar.SimVars vars;
      list<SimCode.Function> functions;
      SimCode.Files files;
      Option<HpcOmSimCode.Schedule> hpcOmSchedule;
      Option<SimCode.BackendMapping> backendMapping;
      Option<HpcOmSimCode.MemoryMap> hpcOmMemory;
      list<SimCode.SimEqSystem> equationsForConditions;
algorithm
  simCodeOut := match(simEqSys,sysIdx,simCodeIn)
    case (_,_,SimCode.SIMCODE(modelInfo, literals, recordDecls, externalFunctionIncludes, allEquations, odeEquations, algebraicEquations, residualEquations, useSymbolicInitialization, useHomotopy, initialEquations, removedInitialEquations, startValueEquations, nominalValueEquations, minValueEquations, maxValueEquations,
                 parameterEquations, removedEquations, algorithmAndEquationAsserts, equationsForZeroCrossings, jacobianEquations, stateSets, constraints, classAttributes, zeroCrossings, relations, timeEvents, whenClauses,
                 discreteModelVars, extObjInfo, makefileParams, delayedExps, jacobianMatrixes, simulationSettingsOpt, fileNamePrefix, hpcOmSchedule, hpcOmMemory, equationsForConditions, crefToSimVarHT, backendMapping))
      equation
        odes = listGet(odeEquations,sysIdx);
        odes = listAppend({simEqSys},odes);
        odeEquations = List.set(odeEquations,sysIdx,odes);
        allEquations = listAppend({simEqSys},allEquations);
      then
        SimCode.SIMCODE(modelInfo, literals, recordDecls, externalFunctionIncludes, allEquations, odeEquations, algebraicEquations, residualEquations, useSymbolicInitialization, useHomotopy, initialEquations, removedInitialEquations, startValueEquations, nominalValueEquations, minValueEquations, maxValueEquations,
                  parameterEquations, removedEquations, algorithmAndEquationAsserts, equationsForZeroCrossings, jacobianEquations, stateSets, constraints, classAttributes, zeroCrossings, relations, timeEvents, whenClauses,
                  discreteModelVars, extObjInfo, makefileParams, delayedExps, jacobianMatrixes, simulationSettingsOpt, fileNamePrefix, hpcOmSchedule, hpcOmMemory, equationsForConditions, crefToSimVarHT,backendMapping);
  end match;
end addSimEqSysToODEquations;

public function addSimEqSysToInitialEquations"adds the given simEqSys to both to the initialEquations"
  input SimCode.SimEqSystem simEqSys;
  input SimCode.SimCode simCodeIn;
  output SimCode.SimCode simCodeOut;
protected
      SimCode.ModelInfo modelInfo;
      list<DAE.Exp> literals;
      list<SimCode.RecordDeclaration> recordDecls;
      list<String> externalFunctionIncludes;
      list<list<SimCode.SimEqSystem>> eqsTmp;
      list<list<SimCode.SimEqSystem>> odeEquations, algebraicEquations;
      list<SimCode.SimEqSystem> allEquations, residualEquations, startValueEquations, nominalValueEquations, minValueEquations, maxValueEquations, parameterEquations, removedEquations, algorithmAndEquationAsserts, jacobianEquations, equationsForZeroCrossings;
      list<SimCode.StateSet> stateSets;
      Boolean useSymbolicInitialization, useHomotopy;
      list<SimCode.SimEqSystem> initialEquations, removedInitialEquations, odes;
      list<DAE.Constraint> constraints;
      list<DAE.ClassAttributes> classAttributes;
      list<BackendDAE.ZeroCrossing> zeroCrossings, relations;
      list<SimCode.SimWhenClause> whenClauses;
      list<DAE.ComponentRef> discreteModelVars;
      SimCode.ExtObjInfo extObjInfo;
      SimCode.MakefileParams makefileParams;
      SimCode.DelayedExpression delayedExps;
      list<SimCode.JacobianMatrix> jacobianMatrixes;
      list<String> labels;
      Option<SimCode.SimulationSettings> simulationSettingsOpt;
      list<BackendDAE.TimeEvent> timeEvents;
      String fileNamePrefix;
      SimCode.HashTableCrefToSimVar crefToSimVarHT;
      Absyn.Path name;
      String description,directory;
      SimCode.VarInfo varInfo;
      SimCodeVar.SimVars vars;
      list<SimCode.Function> functions;
      SimCode.Files files;
      Option<HpcOmSimCode.Schedule> hpcOmSchedule;
      Option<SimCode.BackendMapping> backendMapping;
      Option<HpcOmSimCode.MemoryMap> hpcOmMemory;
      list<SimCode.SimEqSystem> equationsForConditions;
algorithm
  simCodeOut := match(simEqSys,simCodeIn)
    case (_,SimCode.SIMCODE(modelInfo, literals, recordDecls, externalFunctionIncludes, allEquations, odeEquations, algebraicEquations, residualEquations, useSymbolicInitialization, useHomotopy, initialEquations, removedInitialEquations, startValueEquations, nominalValueEquations, minValueEquations, maxValueEquations,
                 parameterEquations, removedEquations, algorithmAndEquationAsserts, equationsForZeroCrossings, jacobianEquations, stateSets, constraints, classAttributes, zeroCrossings, relations, timeEvents, whenClauses,
                 discreteModelVars, extObjInfo, makefileParams, delayedExps, jacobianMatrixes, simulationSettingsOpt, fileNamePrefix, hpcOmSchedule, hpcOmMemory, equationsForConditions, crefToSimVarHT, backendMapping))
      equation
        initialEquations = listAppend(initialEquations,{simEqSys});
      then
        SimCode.SIMCODE(modelInfo, literals, recordDecls, externalFunctionIncludes, allEquations, odeEquations, algebraicEquations, residualEquations, useSymbolicInitialization, useHomotopy, initialEquations, removedInitialEquations, startValueEquations, nominalValueEquations, minValueEquations, maxValueEquations,
                  parameterEquations, removedEquations, algorithmAndEquationAsserts, equationsForZeroCrossings, jacobianEquations, stateSets, constraints, classAttributes, zeroCrossings, relations, timeEvents, whenClauses,
                  discreteModelVars, extObjInfo, makefileParams, delayedExps, jacobianMatrixes, simulationSettingsOpt, fileNamePrefix, hpcOmSchedule, hpcOmMemory, equationsForConditions, crefToSimVarHT,backendMapping);
  end match;
end addSimEqSysToInitialEquations;

public function replaceODEandALLequations"replaces both allEquations and odeEquations"
  input list<SimCode.SimEqSystem> allEqs;
  input list<list<SimCode.SimEqSystem>> odeEqs;
  input SimCode.SimCode simCodeIn;
  output SimCode.SimCode simCodeOut;
protected
      SimCode.ModelInfo modelInfo;
      list<DAE.Exp> literals;
      list<SimCode.RecordDeclaration> recordDecls;
      list<String> externalFunctionIncludes;
      list<list<SimCode.SimEqSystem>> eqsTmp;
      list<list<SimCode.SimEqSystem>> odeEquations, algebraicEquations;
      list<SimCode.SimEqSystem> allEquations, residualEquations, startValueEquations, nominalValueEquations, minValueEquations, maxValueEquations, parameterEquations, removedEquations, algorithmAndEquationAsserts, jacobianEquations, equationsForZeroCrossings;
      list<SimCode.StateSet> stateSets;
      Boolean useSymbolicInitialization, useHomotopy;
      list<SimCode.SimEqSystem> initialEquations, removedInitialEquations, odes;
      list<DAE.Constraint> constraints;
      list<DAE.ClassAttributes> classAttributes;
      list<BackendDAE.ZeroCrossing> zeroCrossings, relations;
      list<SimCode.SimWhenClause> whenClauses;
      list<DAE.ComponentRef> discreteModelVars;
      SimCode.ExtObjInfo extObjInfo;
      SimCode.MakefileParams makefileParams;
      SimCode.DelayedExpression delayedExps;
      list<SimCode.JacobianMatrix> jacobianMatrixes;
      list<String> labels;
      Option<SimCode.SimulationSettings> simulationSettingsOpt;
      list<BackendDAE.TimeEvent> timeEvents;
      String fileNamePrefix;
      SimCode.HashTableCrefToSimVar crefToSimVarHT;
      Absyn.Path name;
      String description,directory;
      SimCode.VarInfo varInfo;
      SimCodeVar.SimVars vars;
      list<SimCode.Function> functions;
      SimCode.Files files;
      Option<HpcOmSimCode.Schedule> hpcOmSchedule;
      Option<SimCode.BackendMapping> backendMapping;
      Option<HpcOmSimCode.MemoryMap> hpcOmMemory;
      list<SimCode.SimEqSystem> equationsForConditions;
algorithm
  simCodeOut := match(allEqs,odeEqs,simCodeIn)
    case (_,_,SimCode.SIMCODE(modelInfo, literals, recordDecls, externalFunctionIncludes, allEquations, odeEquations, algebraicEquations, residualEquations, useSymbolicInitialization, useHomotopy, initialEquations, removedInitialEquations, startValueEquations, nominalValueEquations, minValueEquations, maxValueEquations,
                 parameterEquations, removedEquations, algorithmAndEquationAsserts, equationsForZeroCrossings, jacobianEquations, stateSets, constraints, classAttributes, zeroCrossings, relations, timeEvents, whenClauses,
                 discreteModelVars, extObjInfo, makefileParams, delayedExps, jacobianMatrixes, simulationSettingsOpt, fileNamePrefix, hpcOmSchedule, hpcOmMemory, equationsForConditions, crefToSimVarHT, backendMapping))
      then
        SimCode.SIMCODE(modelInfo, literals, recordDecls, externalFunctionIncludes, allEqs, odeEqs, algebraicEquations, residualEquations, useSymbolicInitialization, useHomotopy, initialEquations, removedInitialEquations, startValueEquations, nominalValueEquations, minValueEquations, maxValueEquations,
                  parameterEquations, removedEquations, algorithmAndEquationAsserts, equationsForZeroCrossings, jacobianEquations, stateSets, constraints, classAttributes, zeroCrossings, relations, timeEvents, whenClauses,
                  discreteModelVars, extObjInfo, makefileParams, delayedExps, jacobianMatrixes, simulationSettingsOpt, fileNamePrefix, hpcOmSchedule, hpcOmMemory, equationsForConditions, crefToSimVarHT,backendMapping);
  end match;
end replaceODEandALLequations;

public function replaceModelInfo"replaces the ModelInfo in SimCode"
  input SimCode.ModelInfo modelInfoIn;
  input SimCode.SimCode simCodeIn;
  output SimCode.SimCode simCodeOut;

algorithm
  simCodeOut := match(modelInfoIn,simCodeIn)
    local
      SimCode.ModelInfo modelInfo;
      list<DAE.Exp> literals;
      list<SimCode.RecordDeclaration> recordDecls;
      list<String> externalFunctionIncludes;
      list<list<SimCode.SimEqSystem>> eqsTmp;
      list<list<SimCode.SimEqSystem>> odeEquations, algebraicEquations;
      list<SimCode.SimEqSystem> allEquations, residualEquations, startValueEquations, nominalValueEquations, minValueEquations, maxValueEquations, parameterEquations, removedEquations, algorithmAndEquationAsserts, jacobianEquations, equationsForZeroCrossings;
      list<SimCode.StateSet> stateSets;
      Boolean useSymbolicInitialization, useHomotopy;
      list<SimCode.SimEqSystem> initialEquations, removedInitialEquations, odes;
      list<DAE.Constraint> constraints;
      list<DAE.ClassAttributes> classAttributes;
      list<BackendDAE.ZeroCrossing> zeroCrossings, relations;
      list<SimCode.SimWhenClause> whenClauses;
      list<DAE.ComponentRef> discreteModelVars;
      SimCode.ExtObjInfo extObjInfo;
      SimCode.MakefileParams makefileParams;
      SimCode.DelayedExpression delayedExps;
      list<SimCode.JacobianMatrix> jacobianMatrixes;
      list<String> labels;
      Option<SimCode.SimulationSettings> simulationSettingsOpt;
      list<BackendDAE.TimeEvent> timeEvents;
      String fileNamePrefix;
      SimCode.HashTableCrefToSimVar crefToSimVarHT;
      Absyn.Path name;
      String description,directory;
      SimCode.VarInfo varInfo;
      SimCodeVar.SimVars vars;
      list<SimCode.Function> functions;
      SimCode.Files files;
      Option<HpcOmSimCode.Schedule> hpcOmSchedule;
      Option<SimCode.BackendMapping> backendMapping;
      Option<HpcOmSimCode.MemoryMap> hpcOmMemory;
      list<SimCode.SimEqSystem> equationsForConditions;
    case (_,SimCode.SIMCODE(_, literals, recordDecls, externalFunctionIncludes, allEquations, odeEquations, algebraicEquations, residualEquations, useSymbolicInitialization, useHomotopy, initialEquations, removedInitialEquations, startValueEquations, nominalValueEquations, minValueEquations, maxValueEquations,
                 parameterEquations, removedEquations, algorithmAndEquationAsserts, equationsForZeroCrossings, jacobianEquations, stateSets, constraints, classAttributes, zeroCrossings, relations, timeEvents, whenClauses,
                 discreteModelVars, extObjInfo, makefileParams, delayedExps, jacobianMatrixes, simulationSettingsOpt, fileNamePrefix, hpcOmSchedule, hpcOmMemory, equationsForConditions, crefToSimVarHT, backendMapping))
      then
        SimCode.SIMCODE(modelInfoIn, literals, recordDecls, externalFunctionIncludes, allEquations, odeEquations, algebraicEquations, residualEquations, useSymbolicInitialization, useHomotopy, initialEquations, removedInitialEquations, startValueEquations, nominalValueEquations, minValueEquations, maxValueEquations,
                  parameterEquations, removedEquations, algorithmAndEquationAsserts, equationsForZeroCrossings, jacobianEquations, stateSets, constraints, classAttributes, zeroCrossings, relations, timeEvents, whenClauses,
                  discreteModelVars, extObjInfo, makefileParams, delayedExps, jacobianMatrixes, simulationSettingsOpt, fileNamePrefix, hpcOmSchedule, hpcOmMemory, equationsForConditions, crefToSimVarHT,backendMapping);
  end match;
end replaceModelInfo;

public function replaceSimEqSysIndex"updated the index of the given SimEqSysIn.
author:Waurich TUD 2014-05"
  input SimCode.SimEqSystem simEqSysIn;
  input Integer idx;
  output SimCode.SimEqSystem simEqSysOut;
algorithm
    simEqSysOut := match(simEqSysIn,idx)
    local
      Boolean pom,lt,changed,ic;
      Integer idxLS,idxNLS,idxMX;
      list<Boolean> bLst;
      DAE.ComponentRef cref;
      DAE.ElementSource source;
      DAE.Exp exp;
      SimCode.SimEqSystem simEqSys;
      list<DAE.Exp> expLst;
      list<DAE.Statement> stmts;
      list<DAE.ComponentRef> crefs;
      list<DAE.ElementSource> sources;
      list<SimCode.SimEqSystem> simEqSysLst,elsebranch;
      list<SimCodeVar.SimVar> simVars;
      list<tuple<Integer, Integer, SimCode.SimEqSystem>> simJac;
      list<tuple<DAE.Exp,list<SimCode.SimEqSystem>>> ifbranches;
      Option<SimCode.JacobianMatrix> jac;
      Option<SimCode.SimEqSystem> elseWhen;
      Boolean homotopySupport;
      Boolean mixedSystem;
    case(SimCode.SES_RESIDUAL(exp=exp,source=source),_)
      equation
        simEqSys = SimCode.SES_RESIDUAL(idx,exp,source);
    then simEqSys;
    case(SimCode.SES_SIMPLE_ASSIGN(cref=cref,exp=exp,source=source),_)
      equation
        simEqSys = SimCode.SES_SIMPLE_ASSIGN(idx,cref,exp,source);
    then simEqSys;
    case(SimCode.SES_ARRAY_CALL_ASSIGN(componentRef=cref,exp=exp,source=source),_)
      equation
        simEqSys = SimCode.SES_ARRAY_CALL_ASSIGN(idx,cref,exp,source);
    then simEqSys;
    case(SimCode.SES_IFEQUATION(ifbranches=ifbranches,elsebranch=elsebranch,source=source),_)
      equation
        simEqSys = SimCode.SES_IFEQUATION(idx,ifbranches,elsebranch,source);
    then simEqSys;
    case(SimCode.SES_ALGORITHM(statements=stmts),_)
      equation
        simEqSys = SimCode.SES_ALGORITHM(idx,stmts);
    then simEqSys;
    case(SimCode.SES_LINEAR(partOfMixed=pom,vars=simVars,beqs=expLst,sources=sources,simJac=simJac,residual=simEqSysLst,jacobianMatrix=jac,indexLinearSystem=idxLS),_)
      equation
        simEqSys = SimCode.SES_LINEAR(idx,pom,simVars,expLst,simJac,simEqSysLst,jac,sources,idxLS);
    then simEqSys;
    case(SimCode.SES_NONLINEAR(eqs=simEqSysLst,crefs=crefs,indexNonLinearSystem=idxNLS,jacobianMatrix=jac,linearTearing=lt,homotopySupport=homotopySupport,mixedSystem=mixedSystem),_)
      equation
        simEqSys = SimCode.SES_NONLINEAR(idx,simEqSysLst,crefs,idxNLS,jac,lt,homotopySupport,mixedSystem);
    then simEqSys;
    case(SimCode.SES_MIXED(cont=simEqSys,discVars=simVars,discEqs=simEqSysLst,indexMixedSystem=idxMX),_)
      equation
        simEqSys = SimCode.SES_MIXED(idx,simEqSys,simVars,simEqSysLst,idxMX);
    then simEqSys;
    case(SimCode.SES_WHEN(conditions=crefs,initialCall=ic,left=cref,right=exp,elseWhen=elseWhen,source=source),_)
      equation
        simEqSys = SimCode.SES_WHEN(idx,crefs,ic,cref,exp,elseWhen,source);
    then simEqSys;
  end match;
end replaceSimEqSysIndex;

public function getMaxSimEqSystemIndex"gets the maximal index of all simEqSystems in the SimCode.
author:Waurich TUD 2014-06"
  input SimCode.SimCode simCode;
  output Integer idxOut;
protected
  Integer idx;
  list<Integer> simEqSysIdcs;
  list<SimCode.SimEqSystem> allEquations,jacobianEquations,equationsForZeroCrossings,algorithmAndEquationAsserts,removedEquations,parameterEquations,maxValueEquations,minValueEquations,nominalValueEquations,startValueEquations,initialEquations;
  list<list<SimCode.SimEqSystem>> odeEquations, algebraicEquations;
algorithm
  SimCode.SIMCODE(allEquations = allEquations, odeEquations=odeEquations, algebraicEquations=algebraicEquations, initialEquations=initialEquations,
                  startValueEquations=startValueEquations, nominalValueEquations=nominalValueEquations, minValueEquations=minValueEquations, maxValueEquations=maxValueEquations,
                    parameterEquations=parameterEquations, removedEquations=removedEquations, algorithmAndEquationAsserts=algorithmAndEquationAsserts,
                   equationsForZeroCrossings=equationsForZeroCrossings, jacobianEquations=jacobianEquations) := simCode;
  idx := 0;
  simEqSysIdcs := List.map(jacobianEquations,eqIndex);
  idx := List.fold(simEqSysIdcs,intMax,idx);
  simEqSysIdcs := List.map(equationsForZeroCrossings,eqIndex);
  idx := List.fold(simEqSysIdcs,intMax,idx);
  simEqSysIdcs := List.map(algorithmAndEquationAsserts,eqIndex);
  idx := List.fold(simEqSysIdcs,intMax,idx);
  simEqSysIdcs := List.map(removedEquations,eqIndex);
  idx := List.fold(simEqSysIdcs,intMax,idx);
  simEqSysIdcs := List.map(parameterEquations,eqIndex);
  idx := List.fold(simEqSysIdcs,intMax,idx);
  simEqSysIdcs := List.map(maxValueEquations,eqIndex);
  idx := List.fold(simEqSysIdcs,intMax,idx);
  simEqSysIdcs := List.map(minValueEquations,eqIndex);
  idx := List.fold(simEqSysIdcs,intMax,idx);
  simEqSysIdcs := List.map(nominalValueEquations,eqIndex);
  idx := List.fold(simEqSysIdcs,intMax,idx);
  simEqSysIdcs := List.map(nominalValueEquations,eqIndex);
  idx := List.fold(simEqSysIdcs,intMax,idx);
  simEqSysIdcs := List.map(startValueEquations,eqIndex);
  idx := List.fold(simEqSysIdcs,intMax,idx);
  simEqSysIdcs := List.map(initialEquations,eqIndex);
  idx := List.fold(simEqSysIdcs,intMax,idx);
  simEqSysIdcs := List.map(allEquations,eqIndex);
  idxOut := List.fold(simEqSysIdcs,intMax,idx);
end getMaxSimEqSystemIndex;

public function getLSindex"outputs the index of the SES_LINEAR or -1"
  input SimCode.SimEqSystem simEqSys;
  output Integer lsIdx;
algorithm
  lsIdx := match(simEqSys)
    local
      Integer idx;
    case(SimCode.SES_LINEAR(indexLinearSystem=idx))
      then idx;
    else
      then -1;
  end match;
end getLSindex;

public function getNLSindex"outputs the index of the SES_NONLINEAR or -1"
  input SimCode.SimEqSystem simEqSys;
  output Integer nlsIdx;
algorithm
  nlsIdx := match(simEqSys)
    local
      Integer idx;
    case(SimCode.SES_NONLINEAR(indexNonLinearSystem=idx))
      then idx;
    else
      then -1;
  end match;
end getNLSindex;

public function getMixedindex"outputs the index of the SES_MIXED or -1"
  input SimCode.SimEqSystem simEqSys;
  output Integer mIdx;
algorithm
  mIdx := match(simEqSys)
    local
      Integer idx;
    case(SimCode.SES_MIXED(indexMixedSystem=idx))
      then idx;
    else
      then -1;
  end match;
end getMixedindex;

public function getRemovedEquationSimEqSysIdxes"gets the simEqSystem - indeces for teh removedEquations
author: Waurich TUD 2014-07"
  input SimCode.SimCode simCode;
  output list<Integer> simEqSysIdcs;
protected
  list<SimCode.SimEqSystem> remEqs;
algorithm
  SimCode.SIMCODE(removedEquations=remEqs) := simCode;
  simEqSysIdcs := List.map(remEqs,eqIndex);
end getRemovedEquationSimEqSysIdxes;

public function getDaeEqsNotPartOfOdeSystem "Get a list of eqSystem-objects that are solved in DAE, but not in the ODE-system.
author: marcusw"
  input SimCode.SimCode iSimCode;
  output list<SimCode.SimEqSystem> oEqs;
protected
  array<Option<SimCode.SimEqSystem>> allEqs;
  list<tuple<Integer, SimCode.SimEqSystem>> allEqIdxMapping; //mapping SimEqIdx -> SimEqSystem
  list<SimCode.SimEqSystem> allEquations;
  list<list<SimCode.SimEqSystem>> odeEquations;
  Integer highestIdx;
  list<SimCode.SimEqSystem> tmpEqs;
algorithm
  SimCode.SIMCODE(allEquations=allEquations,odeEquations=odeEquations) := iSimCode;
  ((allEqIdxMapping, highestIdx)) := List.fold(allEquations, getDaeEqsNotPartOfOdeSystem0, ({}, 0));
  allEqs := arrayCreate(highestIdx, NONE());
  allEqs := List.fold(allEqIdxMapping, getDaeEqsNotPartOfOdeSystem1, allEqs);
  allEqs := List.fold(odeEquations, getDaeEqsNotPartOfOdeSystem2, allEqs);
  tmpEqs := {};
  tmpEqs := Array.fold(allEqs, getDaeEqsNotPartOfOdeSystem4, tmpEqs);
  oEqs := listReverse(tmpEqs);
end getDaeEqsNotPartOfOdeSystem;

protected function getDaeEqsNotPartOfOdeSystem0 "Add the given equation system object to the mapping list (simEqIdx -> SimEqSystem).
author: marcusw"
  input SimCode.SimEqSystem iEqSystem;
  input tuple<list<tuple<Integer, SimCode.SimEqSystem>>, Integer> iMappingWithHighestIdx; //<mapping simEqIdx -> SimEqSystem, highestIdx>
  output tuple<list<tuple<Integer, SimCode.SimEqSystem>>, Integer> oMappingWithHighestIdx;
protected
  Integer index, highestIdx;
  list<tuple<Integer, SimCode.SimEqSystem>> allEqIdxMapping;
algorithm
  index := equationIndex(iEqSystem);
  (allEqIdxMapping, highestIdx) := iMappingWithHighestIdx;
  allEqIdxMapping := (index, iEqSystem)::allEqIdxMapping;
  highestIdx := intMax(highestIdx, index);
  oMappingWithHighestIdx := (allEqIdxMapping, highestIdx);
end getDaeEqsNotPartOfOdeSystem0;

protected function getDaeEqsNotPartOfOdeSystem1 "Set the array at position simEqIdx to the simEqSystem-object.
author: marcusw"
  input tuple<Integer, SimCode.SimEqSystem> iEqSystem; //<simEqIdx, simEqSystem>
  input array<Option<SimCode.SimEqSystem>> iEqArray;
  output array<Option<SimCode.SimEqSystem>> oEqArray;
protected
  Integer eqSysIdx;
  SimCode.SimEqSystem eqSys;
algorithm
  (eqSysIdx, eqSys) := iEqSystem;
  oEqArray := arrayUpdate(iEqArray, eqSysIdx, SOME(eqSys));
end getDaeEqsNotPartOfOdeSystem1;

protected function getDaeEqsNotPartOfOdeSystem2 "Set the array at position simEqIdx to NONE().
author: marcusw"
  input list<SimCode.SimEqSystem> iEqSystem;
  input array<Option<SimCode.SimEqSystem>> iEqArray;
  output array<Option<SimCode.SimEqSystem>> oEqArray;
algorithm
  oEqArray := List.fold(iEqSystem, getDaeEqsNotPartOfOdeSystem3, iEqArray);
end getDaeEqsNotPartOfOdeSystem2;

protected function getDaeEqsNotPartOfOdeSystem3 "Set the array at position simEqIdx to NONE().
author: marcusw"
  input SimCode.SimEqSystem iEqSystem;
  input array<Option<SimCode.SimEqSystem>> iEqArray;
  output array<Option<SimCode.SimEqSystem>> oEqArray;
protected
  Integer eqSysIdx;
  SimCode.SimEqSystem eqSys;
algorithm
  eqSysIdx := equationIndex(iEqSystem);
  oEqArray := arrayUpdate(iEqArray, eqSysIdx, NONE());
end getDaeEqsNotPartOfOdeSystem3;

protected function getDaeEqsNotPartOfOdeSystem4 "Append the element to the list if it is not NONE().
author: marcusw"
  input Option<SimCode.SimEqSystem> iEqSystemOpt;
  input list<SimCode.SimEqSystem> iResList;
  output list<SimCode.SimEqSystem> oResList;
protected
  SimCode.SimEqSystem eqSys;
algorithm
  oResList := match(iEqSystemOpt, iResList)
    case(SOME(eqSys), _)
      then eqSys::iResList;
    else
      then iResList;
  end match;
end getDaeEqsNotPartOfOdeSystem4;

public function dumpIdxScVarMapping
  input array<Option<SimCodeVar.SimVar>> iMapping;
algorithm
  print("Idx-ScVar-Mapping:\n");
  _ := Array.fold(iMapping, dumpIdxScVarMapping0, 1);
end dumpIdxScVarMapping;

protected function dumpIdxScVarMapping0
  input Option<SimCodeVar.SimVar> iVar;
  input Integer iIdx;
  output Integer oIdx;
protected
  DAE.ComponentRef name;
  String refString;
algorithm
  oIdx := match(iVar, iIdx)
    case(SOME(SimCodeVar.SIMVAR(name=name)), _)
      equation
        print("Idx: " + intString(iIdx) + " -- ");
        refString = ComponentReference.printComponentRefStr(name);
        print(refString + "\n");
      then iIdx + 1;
    else iIdx + 1;
  end match;
end dumpIdxScVarMapping0;

protected function dumpBackendMapping"dump function for the backendmapping
author:Waurich TUD 2014-04"
  input SimCode.BackendMapping mapIn;
protected
  array<Integer> eqMatch,varMatch;
  array<list<Integer>> tree;
  list<tuple<Integer,list<Integer>>> eqMapping;
  list<tuple<Integer,Integer>> varMapping;
  BackendDAE.IncidenceMatrix m;
  BackendDAE.IncidenceMatrixT mt;
  array<list<SimCodeVar.SimVar>> simVarMapping;
algorithm
  SimCode.BACKENDMAPPING(m=m,mT=mt,eqMapping=eqMapping,varMapping=varMapping,eqMatch=eqMatch,varMatch=varMatch,eqTree=tree,simVarMapping=simVarMapping) := mapIn;
  dumpEqMapping(eqMapping);
  /*
  dumpVarMapping(varMapping);
  print("\nthe incidence Matrix (backendIndices)\n");
  BackendDump.dumpIncidenceMatrix(m);
  BackendDump.dumpIncidenceMatrixT(mt);
  print("\nvars matched to eq (backend indeces)\n");
  BackendDump.dumpMatching(varMatch);
  print("\nequations tree (rows:backendEqs, entrys: list of required backend equations)");
  BackendDump.dumpIncidenceMatrix(tree);
  */
end dumpBackendMapping;

protected function dumpEqMapping"dump function for the equation mapping
author:Waurich TUD 2014-04"
  input list<tuple<Integer,list<Integer>>> eqMapping;
protected
  list<tuple<Integer,list<Integer>>> lst;
  list<String> s;
algorithm
  lst := listReverse(eqMapping);
  print("------------\n");
  print("BackendEquation ---> SimEqSys\n");
  (s,_) := List.mapFold(lst,dumpEqMappingTuple,1);
  print(stringDelimitList(s,"\n"));
  print("\n------------\n");
  print("\n");
end dumpEqMapping;

protected function dumpVarMapping"dump function for the variable mapping.
author:Waurich TUD 2014-04"
  input list<tuple<Integer,Integer>> varMapping;
protected
  list<tuple<Integer,Integer>> lst;
  list<String> s;
algorithm
  lst := listReverse(varMapping);
  print("------------\n");
  print("BackendVar ---> SimVar\n");
  (s,_) := List.mapFold(lst,dumpVarMappingTuple,1);
  print(stringDelimitList(s,"\n"));
  print("\n------------\n");
  print("\n");
end dumpVarMapping;

protected function dumpEqMappingTuple"outputs a string for a equation mapping tuple.
author:Waurich TUD 2014-04"
  input tuple<Integer,list<Integer>> tpl;
  input Integer noIn;
  output String s;
  output Integer noOut;
protected
  Integer i1;
  list<Integer> lst;
algorithm
   (i1,lst) := tpl;
   s := intString(noIn)+"): "+stringDelimitList(List.map(lst,intString),",")+" ---> "+intString(i1);
   noOut := noIn+1;
end dumpEqMappingTuple;

protected function dumpVarMappingTuple"outputs a string for a variable mapping tuple.
author:Waurich TUD 2014-04"
  input tuple<Integer,Integer> tpl;
  input Integer noIn;
  output String s;
  output Integer noOut;
protected
  Integer i1, i2;
algorithm
   (i1,i2) := tpl;
   s := intString(noIn)+"): "+intString(i2)+" ---> "+intString(i1);
   noOut := noIn+1;
end dumpVarMappingTuple;

public function getFMIModelStructure
" function detectes the model stucture for FMI 2.0
  by analyzing the symbolic jacobian matrixes and sparsity pattern"
  input SimCode.SimCode simCode;
  input list<SimCode.JacobianMatrix> jacobianMatrixes; // Matrixes A,B,C,D
  output SimCode.FmiModelStructure outFmiModelStructure;
protected
   SimCode.JacobianMatrix A,B,C,D;
   list<tuple<DAE.ComponentRef, list<DAE.ComponentRef>>> spTA, spTB;
   list<tuple<Integer, list<Integer>>> spTInts;
   list<SimCode.FmiUnknown> derivatives, outputs;
algorithm
  // combine the transposed sparse pattern of matrix A and B
  // to obtain dependencies for the derivatives

  SOME(A as (_, _, _, (_,spTA,_), _, _, _)) := getJacobianMatrix(jacobianMatrixes, "A");
  SOME(B as (_, _, _, (_,spTB,_), _, _, _)) := getJacobianMatrix(jacobianMatrixes, "B");

  spTA  := mergeSparsePatter(spTA, spTB, {});
  // expand cref to der(cref), since diffed crefs are states
  // but mean der(crefs)
  spTA := translateSparsePatterCref2DerCref(spTA, {});

  // translate crefs -> simvars integers via cref2simvars
  spTInts := translateSparsePatterSimVarInts(spTA, simCode);
  spTInts := List.sort(spTInts, compareSparsePatterInt);
  derivatives := translateSparsePatterInts2FMIUnknown(spTInts, {});

  // combine the transposed sparse pattern of matrix C and D
  // to obtain dependencies for the outputs
  SOME(C as (_, _, _, (_,spTA,_), _, _, _)) := getJacobianMatrix(jacobianMatrixes, "C");
  SOME(D as (_, _, _, (_,spTB,_), _, _, _)) := getJacobianMatrix(jacobianMatrixes, "D");

  spTA  := mergeSparsePatter(spTA, spTB, {});

  // translate crefs -> simvars integers via cref2simvars
  spTInts := translateSparsePatterSimVarInts(spTA, simCode);
  spTInts := List.sort(spTInts, compareSparsePatterInt);
  outputs := translateSparsePatterInts2FMIUnknown(spTInts, {});

  //output results
  outFmiModelStructure := SimCode.FMIMODELSTRUCTURE(SimCode.FMIOUTPUTS(outputs), SimCode.FMIDERIVATIVES(derivatives), SimCode.FMIINITIALUNKNOWNS({}));
end getFMIModelStructure;

protected function translateSparsePatterInts2FMIUnknown
"function translates simVar integers to fmi unknowns."
  input list<tuple<Integer, list<Integer>>> inSparsePattern;
  input list<SimCode.FmiUnknown> inAccum;
  output list<SimCode.FmiUnknown> outFmiUnknown;
algorithm
  outFmiUnknown := match(inSparsePattern, inAccum)
    local
      list<tuple<Integer, list<Integer>>> rest;
      Integer unknown;
      list<Integer> dependencies;
      list<String> dependenciesKind;

    case ({}, _) then listReverse(inAccum);

    case ( ((unknown, dependencies))::rest, _)
      equation
        // for now dependenciesKind is set to dependent
        dependenciesKind = List.fill("dependent", listLength(dependencies));
      then
        translateSparsePatterInts2FMIUnknown(rest, SimCode.FMIUNKNOWN(unknown, dependencies, dependenciesKind)::inAccum);

     end match;
end translateSparsePatterInts2FMIUnknown;

protected function translateSparsePatterCref2DerCref
"function translates the first cref of sparse pattern to der(cref)"
  input list<tuple<DAE.ComponentRef, list<DAE.ComponentRef>>> sparsePattern;
  input list<tuple<DAE.ComponentRef, list<DAE.ComponentRef>>> inAccum;
  output list<tuple<DAE.ComponentRef, list<DAE.ComponentRef>>> outSparsePattern;
algorithm
  outSparsePattern := match(sparsePattern, inAccum)
    local
      DAE.ComponentRef cref;
      list<DAE.ComponentRef> crefs;
      list<tuple<DAE.ComponentRef, list<DAE.ComponentRef>>> rest;

    case ({}, _) then listReverse(inAccum);

    case ( ((cref, crefs))::rest, _)
      equation
        cref = ComponentReference.crefPrefixDer(cref);
      then
        translateSparsePatterCref2DerCref(rest, (cref, crefs)::inAccum);

     end match;
end translateSparsePatterCref2DerCref;

public function translateSparsePatterSimVarInts
"function translates sparse pattern to simVar index"
  input list<tuple<DAE.ComponentRef, list<DAE.ComponentRef>>> sparsePattern;
  input SimCode.SimCode simCode;
  output list<tuple<Integer, list<Integer>>> outSparsePattern;
algorithm
  outSparsePattern := match(sparsePattern, simCode)
    local
      list<tuple<DAE.ComponentRef, list<DAE.ComponentRef>>> all;

    case ({}, _) then {};

    case (_, _)
     then translateSparsePatterSimVarIntsWork(sparsePattern, simCode, {});

     end match;
end translateSparsePatterSimVarInts;

protected function translateSparsePatterSimVarIntsWork
"function translates sparse pattern to simVar index"
  input list<tuple<DAE.ComponentRef, list<DAE.ComponentRef>>> sparsePattern;
  input SimCode.SimCode simCode;
  input list<tuple<Integer, list<Integer>>> inAccum;
  output list<tuple<Integer, list<Integer>>> outSparsePattern;
algorithm
  outSparsePattern := match(sparsePattern, simCode, inAccum)
    local
      DAE.ComponentRef cref;
      list<DAE.ComponentRef> crefs;
      list<tuple<DAE.ComponentRef, list<DAE.ComponentRef>>> rest;
      Integer unknown;
      list<Integer> dependencies;

    case ({}, _, _) then listReverse(inAccum);

    case ( ((cref, crefs))::rest, _, _)
      equation
        unknown = translateCref2SimVarIndex(cref, simCode);
        dependencies = List.map1(crefs, translateCref2SimVarIndex, simCode);
      then
        translateSparsePatterSimVarIntsWork(rest, simCode, (unknown, dependencies)::inAccum);

     end match;
end translateSparsePatterSimVarIntsWork;

public function translateColorsSimVarInts
"function translates sparse pattern to simVar index"
  input list<list<DAE.ComponentRef>> inColors;
  input SimCode.SimCode simCode;
  output list<list<Integer>> outColors;
algorithm
  outColors := match(inColors, simCode)
    local
      list<list<DAE.ComponentRef>> all;

    case ({}, _) then {};

    case (all, _)
     then List.mapList1_1(all, translateCref2SimVarIndex, simCode);

     end match;
end translateColorsSimVarInts;

protected function compareSparsePatterInt
"function translates the first cref of sparse pattern to der(cref)"
  input tuple<Integer, list<Integer>> elementA;
  input tuple<Integer, list<Integer>> elementB;
  output Boolean out;
protected
  Integer a,b;
algorithm
  (a, _) := elementA;
  (b, _) := elementB;
  out := intGt(a, b);
end compareSparsePatterInt;

protected function translateCref2SimVarIndex
  input DAE.ComponentRef inCref;
  input SimCode.SimCode simCode;
  output Integer out;
algorithm
  SimCodeVar.SIMVAR(variable_index = SOME(out)) := cref2simvar(inCref, simCode);
end translateCref2SimVarIndex;

protected function getJacobianMatrix
  input list<SimCode.JacobianMatrix> injacobianMatrixes;
  input String inJacobianName;
  output Option<SimCode.JacobianMatrix> outMatrix;
algorithm
  outMatrix := matchcontinue(injacobianMatrixes, inJacobianName)
    local
      SimCode.JacobianMatrix matrix;
      list<SimCode.JacobianMatrix> rest;
      String name;
      case ( (matrix as (_, _, name, _, _, _, _))::_, _)
        equation
          true = stringEq(name, inJacobianName);
       then SOME(matrix);
       case ( _::rest, _)
        then getJacobianMatrix(rest, inJacobianName);
       else then NONE();
  end matchcontinue;
end getJacobianMatrix;

protected function mergeSparsePatter
  input list<tuple<DAE.ComponentRef, list<DAE.ComponentRef>>> inA;
  input list<tuple<DAE.ComponentRef, list<DAE.ComponentRef>>> inB;
  input list<tuple<DAE.ComponentRef, list<DAE.ComponentRef>>> inAccum;
  output list<tuple<DAE.ComponentRef, list<DAE.ComponentRef>>> out;
algorithm
  out := match(inA, inB, inAccum)
  local
    list<tuple<DAE.ComponentRef, list<DAE.ComponentRef>>> restA, restB;
    DAE.ComponentRef crefA, crefB;
    list<DAE.ComponentRef> listA, listB, listOut;

    case ( {}, {}, _) then listReverse(inAccum);

    case ( {}, _, _) then inB;

    case ( _, {}, _) then inA;

    case (( (crefA, listA) )::restA, ((crefB, listB))::restB, _)
      equation
        true = ComponentReference.crefEqual(crefA, crefB);
        listOut = List.unionOnTrue(listA, listB, ComponentReference.crefEqual);
      then
         mergeSparsePatter(restA, restB, (crefA,listOut)::inAccum);
   end match;
end mergeSparsePatter;

public function getStateSimVarIndexFromIndex
  input list<SimCodeVar.SimVar> inStateVars;
  input Integer inIndex;
  output Integer outVariableIndex;
protected
  SimCodeVar.SimVar stateVar;
algorithm
  stateVar := listGet(inStateVars, inIndex + 1 /* SimVar indexes start from zero */);
  outVariableIndex := getVariableIndex(stateVar);
end getStateSimVarIndexFromIndex;

public function getVariableIndex
  input SimCodeVar.SimVar inVar;
  output Integer outVariableIndex;
algorithm
  outVariableIndex := match (inVar)
    local
      Integer variableIndex;
    case (SimCodeVar.SIMVAR(variable_index = SOME(variableIndex)))
    then variableIndex;
    else 0;
  end match;
end getVariableIndex;

public function execStat
  "Prints an execution stat on the format:
  *** %name% -> time: %time%, memory %memory%
  Where you provide name, and time is the time since the last call using this
  index (the clock is reset after each call). The memory is the total memory
  consumed by the compiler at this point in time.
  "
  input String name;
algorithm
  execStat2(Flags.isSet(Flags.EXEC_STAT),name);
end execStat;

protected function execStat2
  input Boolean cond;
  input String name;
algorithm
  _ := match (cond,name)
    local
      Real t,total,used,allocated;
      String timeStr,totalTimeStr,gcStr;
    case (false,_) then ();
    else
      equation
        t = System.realtimeTock(ClockIndexes.RT_CLOCK_EXECSTAT);
        total = System.realtimeTock(ClockIndexes.RT_CLOCK_EXECSTAT_CUMULATIVE);
        gcStr = GC.profStatsStr(GC.getProfStats(), head="");
        timeStr = System.snprintff("%.4g",20,t);
        totalTimeStr = System.snprintff("%.4g",20,total);
        Error.addMessage(Error.EXEC_STAT,{name,timeStr,totalTimeStr,gcStr});
        System.realtimeTick(ClockIndexes.RT_CLOCK_EXECSTAT);
      then ();
  end match;
end execStat2;

annotation(__OpenModelica_Interface="backend");
end SimCodeUtil;
